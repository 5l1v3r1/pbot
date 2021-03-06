# File: Commands.pm
#
# Author: pragma_
#
# Purpose: Registers commands. Invokes commands with user capability
# validation.

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

package PBot::Commands;
use parent 'PBot::Class', 'PBot::Registerable';

use warnings; use strict;
use feature 'unicode_strings';

use Time::Duration qw/duration/;

sub initialize {
    my ($self, %conf) = @_;
    $self->PBot::Registerable::initialize(%conf);

    $self->{metadata} = PBot::HashObject->new(pbot => $self->{pbot}, name => 'Commands', filename => $conf{filename});
    $self->{metadata}->load;

    $self->register(sub { $self->cmdset(@_) },     "cmdset",   1);
    $self->register(sub { $self->cmdunset(@_) },   "cmdunset", 1);
    $self->register(sub { $self->help(@_) },       "help",     0);
    $self->register(sub { $self->uptime(@_) },     "uptime",   0);
    $self->register(sub { $self->in_channel(@_) }, "in",       1);

    $self->{pbot}->{capabilities}->add('admin', 'can-in', 1);
}

sub register {
    my ($self, $subref, $name, $requires_cap) = @_;
    Carp::croak("Missing parameters to Commands::register") if not defined $subref or not defined $name;

    my $ref = $self->PBot::Registerable::register($subref);
    $ref->{name}         = lc $name;
    $ref->{requires_cap} = $requires_cap // 0;

    if (not $self->{metadata}->exists($name)) { $self->{metadata}->add($name, {requires_cap => $requires_cap, help => ''}, 1); }
    else {
        if (not defined $self->get_meta($name, 'requires_cap')) { $self->{metadata}->set($name, 'requires_cap', $requires_cap, 1); }
    }

    # add can-cmd capability
    $self->{pbot}->{capabilities}->add("can-$name", undef, 1) if $requires_cap;
    return $ref;
}

sub unregister {
    my ($self, $name) = @_;
    Carp::croak("Missing name parameter to Commands::unregister") if not defined $name;
    $name = lc $name;
    @{$self->{handlers}} = grep { $_->{name} ne $name } @{$self->{handlers}};
}

sub exists {
    my ($self, $keyword) = @_;
    $keyword = lc $keyword;
    foreach my $ref (@{$self->{handlers}}) { return 1 if $ref->{name} eq $keyword; }
    return 0;
}

sub interpreter {
    my ($self, $stuff) = @_;
    my $result;

    if ($self->{pbot}->{registry}->get_value('general', 'debugcontext')) {
        use Data::Dumper;
        $Data::Dumper::Sortkeys = 1;
        $self->{pbot}->{logger}->log("Commands::interpreter\n");
        $self->{pbot}->{logger}->log(Dumper $stuff);
    }

    my $keyword = lc $stuff->{keyword};
    my $from    = $stuff->{from};

    my ($cmd_channel) = $stuff->{arguments} =~ m/\B(#[^ ]+)/;    # assume command is invoked in regards to first channel-like argument
    $cmd_channel = $from if not defined $cmd_channel;            # otherwise command is invoked in regards to the channel the user is in
    my $user = $self->{pbot}->{users}->find_user($cmd_channel, "$stuff->{nick}!$stuff->{user}\@$stuff->{host}");

    my $cap_override;
    if (exists $stuff->{'cap-override'}) {
        $self->{pbot}->{logger}->log("Override cap to $stuff->{'cap-override'}\n");
        $cap_override = $stuff->{'cap-override'};
    }

    foreach my $ref (@{$self->{handlers}}) {
        if ($ref->{name} eq $keyword) {
            my $requires_cap = $self->get_meta($keyword, 'requires_cap') // $ref->{requires_cap};
            if ($requires_cap) {
                if (defined $cap_override) {
                    if (not $self->{pbot}->{capabilities}->has($cap_override, "can-$keyword")) {
                        return "/msg $stuff->{nick} The $keyword command requires the can-$keyword capability, which cap-override $cap_override does not have.";
                    }
                } else {
                    if (not defined $user) {
                        my ($found_chan, $found_mask) = $self->{pbot}->{users}->find_user_account($cmd_channel, "$stuff->{nick}!$stuff->{user}\@$stuff->{host}", 1);
                        if   (not defined $found_chan) { return "/msg $stuff->{nick} You must have a user account to use $keyword."; }
                        else                           { return "/msg $stuff->{nick} You must have a user account in $cmd_channel to use $keyword. (You have an account in $found_chan.)"; }
                    } elsif (not $user->{loggedin}) {
                        return "/msg $stuff->{nick} You must be logged into your user account to use $keyword.";
                    }

                    if (not $self->{pbot}->{capabilities}->userhas($user, "can-$keyword")) {
                        return "/msg $stuff->{nick} The $keyword command requires the can-$keyword capability, which your user account does not have.";
                    }
                }
            }

            $stuff->{action} = $stuff->{arguments};
            $stuff->{arguments} = $self->{pbot}->{factoids}->expand_factoid_vars($stuff);
            $stuff->{arguments} = $self->{pbot}->{factoids}->expand_special_vars($stuff->{from}, $stuff->{nick}, $stuff->{keyword}, $stuff->{arguments});
            delete $stuff->{action};

            $stuff->{no_nickoverride} = 1;
            if ($self->get_meta($keyword, 'background-process')) {
                my $timeout = $self->get_meta($keyword, 'process-timeout') // $self->{pbot}->{registry}->get_value('processmanager', 'default_timeout');
                $self->{pbot}->{process_manager}->execute_process(
                    $stuff,
                    sub { $stuff->{result} = $ref->{subref}->($stuff->{from}, $stuff->{nick}, $stuff->{user}, $stuff->{host}, $stuff->{arguments}, $stuff) },
                    $timeout
                );
                return "";
            } else {
                my $result = $ref->{subref}->($stuff->{from}, $stuff->{nick}, $stuff->{user}, $stuff->{host}, $stuff->{arguments}, $stuff);
                return undef if $stuff->{referenced} and $result =~ m/(?:usage:|no results)/i;
                return $result;
            }
        }
    }
    return undef;
}

sub set_meta {
    my ($self, $command, $key, $value, $save) = @_;
    return undef if not $self->{metadata}->exists($command);
    $self->{metadata}->set($command, $key, $value, !$save);
    return 1;
}

sub get_meta {
    my ($self, $command, $key) = @_;
    return $self->{metadata}->get_data($command, $key);
}

sub cmdset {
    my ($self, $from, $nick, $user, $host, $arguments, $stuff) = @_;
    my ($command, $key, $value) = $self->{pbot}->{interpreter}->split_args($stuff->{arglist}, 3);
    return "Usage: cmdset <command> [key [value]]" if not defined $command;
    return $self->{metadata}->set($command, $key, $value);
}

sub cmdunset {
    my ($self, $from, $nick, $user, $host, $arguments, $stuff) = @_;
    my ($command, $key) = $self->{pbot}->{interpreter}->split_args($stuff->{arglist}, 2);
    return "Usage: cmdunset <command> <key>" if not defined $command or not defined $key;
    return $self->{metadata}->unset($command, $key);
}

sub help {
    my ($self, $from, $nick, $user, $host, $arguments, $stuff) = @_;

    if (not length $arguments) {
        return "For general help, see <https://github.com/pragma-/pbot/tree/master/doc>. For help about a specific command or factoid, use `help <keyword> [channel]`.";
    }

    my $keyword = lc $self->{pbot}->{interpreter}->shift_arg($stuff->{arglist});

    # check built-in commands first
    if ($self->exists($keyword)) {
        if ($self->{metadata}->exists($keyword)) {
            my $name         = $self->{metadata}->get_data($keyword, '_name');
            my $requires_cap = $self->{metadata}->get_data($keyword, 'requires_cap');
            my $help         = $self->{metadata}->get_data($keyword, 'help');
            my $result       = "/say $name: ";
            $result .= "[Requires can-$keyword] " if $requires_cap;

            if   (not defined $help or not length $help) { $result .= "I have no help for this command yet."; }
            else                                         { $result .= $help; }
            return $result;
        }
        return "$keyword is a built-in command, but I have no help for it yet.";
    }

    # then factoids
    my $channel_arg = $self->{pbot}->{interpreter}->shift_arg($stuff->{arglist});
    $channel_arg = $from if not defined $channel_arg or not length $channel_arg;
    $channel_arg = '.*'  if $channel_arg !~ m/^#/;

    my @factoids = $self->{pbot}->{factoids}->find_factoid($channel_arg, $keyword, exact_trigger => 1);

    if (not @factoids or not $factoids[0]) { return "I don't know anything about $keyword."; }

    my ($channel, $trigger);

    if (@factoids > 1) {
        if (not grep { $_->[0] eq $channel_arg } @factoids) {
            return
                "/say $keyword found in multiple channels: "
              . (join ', ', sort map { $_->[0] eq '.*' ? 'global' : $_->[0] } @factoids)
              . "; use `help $keyword <channel>` to disambiguate.";
        } else {
            foreach my $factoid (@factoids) {
                if ($factoid->[0] eq $channel_arg) {
                    ($channel, $trigger) = ($factoid->[0], $factoid->[1]);
                    last;
                }
            }
        }
    } else {
        ($channel, $trigger) = ($factoids[0]->[0], $factoids[0]->[1]);
    }

    my $channel_name = $self->{pbot}->{factoids}->{factoids}->get_data($channel, '_name');
    my $trigger_name = $self->{pbot}->{factoids}->{factoids}->get_data($channel, $trigger, '_name');
    $channel_name = 'global channel'    if $channel_name eq '.*';
    $trigger_name = "\"$trigger_name\"" if $trigger_name =~ / /;

    my $result = "/say ";
    $result .= "[$channel_name] " if $channel ne $from and $channel ne '.*';
    $result .= "$trigger_name: ";

    my $help = $self->{pbot}->{factoids}->{factoids}->get_data($channel, $trigger, 'help');

    if (not defined $help or not length $help) { return "/say $trigger_name is a factoid for $channel_name, but I have no help for it yet."; }

    $result .= $help;
    return $result;
}

sub uptime {
    my ($self, $from, $nick, $user, $host, $arguments, $stuff) = @_;
    return localtime($self->{pbot}->{startup_timestamp}) . " [" . duration(time - $self->{pbot}->{startup_timestamp}) . "]";
}

sub in_channel {
    my ($self, $from, $nick, $user, $host, $arguments, $stuff) = @_;

    my $usage = "Usage: in <channel> <command>";
    return $usage if not $arguments;

    my ($channel, $command) = $self->{pbot}->{interpreter}->split_args($stuff->{arglist}, 2, 0, 1);
    return $usage if not defined $channel or not defined $command;

    if (not $self->{pbot}->{nicklist}->is_present($channel, $nick)) { return "You must be present in $channel to do this."; }

    $stuff->{from}    = $channel;
    $stuff->{command} = $command;
    return $self->{pbot}->{interpreter}->interpret($stuff);
}

1;
