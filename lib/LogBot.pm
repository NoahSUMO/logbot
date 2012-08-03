package LogBot;

use strict;
use warnings;
use feature qw(switch);

use LogBot::Config;
use LogBot::ConfigFile;
use LogBot::Constants;
use LogBot::Daemon;
use LogBot::Network;

use fields qw(
    _config_filename
    _config
    _networks
    _is_daemon
    _actions
);

#
# initialisation
#

# this class is a singleton
my $self;

sub initialised {
    return $self ? 1 : 0;
}

sub new {
    my ($class, $config_filename) = @_;

    $self ||= fields::new($class);

    $self->{_config_filename} = $config_filename;
    $self->{_is_daemon} = 0;
    $self->{_actions} = [];

    return $self;
}

sub instance {
    return $self;
}

sub reload {
    my ($class) = @_;

    my $config_file = LogBot::ConfigFile->new($self->{_config_filename});

    $self->{_config} = LogBot::Config->new(
        bot => $config_file->{bot},
        web => $config_file->{web},
        data_path => $config_file->{data_path},
        tmpl_path => $config_file->{tmpl_path},
    );

    foreach my $network_name (sort keys %{ $config_file->{networks} }) {
        my $config_network = $config_file->{networks}->{$network_name};
        my %args = (
            network  => $network_name,
            server   => $config_network->{server},
            port     => $config_network->{port},
            nick     => $config_network->{nick},
            name     => $config_network->{name},
            password => $config_network->{password},
            bots     => $config_network->{bots},
        );
        my $network = $self->network($network_name);
        if (!$network) {
            $network = LogBot::Network->new(%args);
            $self->{_networks}->{$network_name} = $network;
        } else {
            $network->reconfigure(%args);
        }

        # XXX delete network

        foreach my $channel_name (sort keys %{ $config_network->{channels} }) {
            my $config_channel = $config_network->{channels}->{$channel_name};
            %args = (
                network           => $network,
                name              => $channel_name,
                public            => $config_channel->{public},
                in_channel_search => $config_channel->{in_channel_search},
                log_events        => $config_channel->{log_events},
                join              => $config_channel->{join},
            );
            my $channel = $network->channel($channel_name);
            if (!$channel) {
                $channel = LogBot::Channel->new(%args);
                $network->add_channel($channel);
            } else {
                $channel->reconfigure(%args);
            }
        }

        foreach my $channel ($network->channels) {
            next if exists $config_network->{channels}->{$channel->{name}};
            $network->remove_channel($channel);
        }

        if ($self->is_daemon) {
            $self->do_actions();
        }
    }
}

sub connect {
    $self->{_is_daemon} = 1;
    $self->reload();
}

sub is_daemon {
    return $self->{_is_daemon};
}

sub config {
    return $self->{_config};
}

sub networks {
    return
        sort { $a->{network} cmp $b->{network} }
        values %{ $self->{_networks} };
}

sub network {
    my ($class, $name) = @_;
    if (!exists $self->{_networks}->{$name}) {
        return;
    }
    return $self->{_networks}->{$name};
}

sub action {
    my ($class, $type, $network, $channel) = @_;
    return unless $self->is_daemon;
    push @{ $self->{_actions} }, {
        type    => $type,
        network => $network,
        channel => $channel,
    };
}

sub do_actions {
    while (my $action = shift @{ $self->{_actions} }) {
        my ($network, $channel) = ($action->{network}, $action->{channel});
        given($action->{type}) {
            when(ACTION_NETWORK_CONNECT) {
                printf "action: connect %s\n", $network->{name};
                $self->_remove_actions(network => $network);
                $network->connect();
            }
            when(ACTION_NETWORK_RECONNECT) {
                printf "action: reconnect %s\n", $network->{name};
                $self->_remove_actions(network => $network);
                $network->disconnect();
                $network->connect();
            }
            when(ACTION_NETWORK_NICK) {
                printf "action: nick %s\n", $network->{name};
                die "not implemented";
            }
            when(ACTION_NETWORK_DISCONNECT) {
                printf "action: disconnect %s\n", $network->{name};
                $self->_remove_actions(network => $network);
                $network->disconnect();
            }
            when(ACTION_CHANNEL_JOIN) {
                printf "action: join %s\n", $channel->{name};
                $self->_remove_actions(channel => $channel);
                $network->{bot}->join($channel);
            }
            when(ACTION_CHANNEL_PART) {
                printf "action: part %s\n", $channel->{name};
                $self->_remove_actions(channel => $channel);
                $network->{bot}->part($channel);
            }
        }
    }
}

sub _remove_actions {
    my ($class, %args) = @_;

    foreach my $name (keys %args) {
        my $object = $args{$name};
        $self->{_actions} = [
            grep { $_->{$name} eq $object}
            @{ $self->{_actions} }
        ];
    }
}

1;
