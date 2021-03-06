# File: ChanOps.pm
# Author: pragma_
#
# Purpose: Provides channel operator status tracking and commands.

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

package PBot::ChanOps;

use parent 'PBot::Class';

use warnings; use strict;
use feature 'unicode_strings';

use PBot::ChanOpCommands;
use Time::HiRes qw(gettimeofday);
use Time::Duration qw(concise duration);

sub initialize {
    my ($self, %conf) = @_;

    $self->{unban_timeout} = PBot::DualIndexHashObject->new(
        pbot     => $self->{pbot},
        name     => 'Unban Timeouts',
        filename => $self->{pbot}->{registry}->get_value('general', 'data_dir') . '/unban_timeouts'
    );

    $self->{unban_timeout}->load;

    $self->{unmute_timeout} = PBot::DualIndexHashObject->new(
        pbot     => $self->{pbot},
        name     => 'Unmute Timeouts',
        filename => $self->{pbot}->{registry}->get_value('general', 'data_dir') . '/unmute_timeouts'
    );

    $self->{unmute_timeout}->load;

    $self->enqueue_timeouts;

    $self->{ban_queue}   = {};
    $self->{unban_queue} = {};

    $self->{op_commands}  = {};
    $self->{is_opped}     = {};
    $self->{op_requested} = {};

    $self->{commands} = PBot::ChanOpCommands->new(pbot => $self->{pbot});

    $self->{pbot}->{registry}->add_default('text', 'general', 'deop_timeout', 300);

    $self->{pbot}->{timer}->register(sub { $self->check_opped_timeouts },  10, 'Check Opped Timeouts');
    $self->{pbot}->{timer}->register(sub { $self->check_unban_queue },     30, 'Check Unban Queue');
}

sub can_gain_ops {
    my ($self, $channel) = @_;
    $channel = lc $channel;
    return
         $self->{pbot}->{channels}->{channels}->exists($channel)
      && $self->{pbot}->{channels}->{channels}->get_data($channel, 'chanop')
      && $self->{pbot}->{channels}->{channels}->get_data($channel, 'enabled');
}

sub gain_ops {
    my $self    = shift;
    my $channel = shift;
    $channel = lc $channel;

    return if exists $self->{op_requested}->{$channel};
    return if not $self->can_gain_ops($channel);

    my $op_nick = $self->{pbot}->{registry}->get_value($channel, 'op_nick') // $self->{pbot}->{registry}->get_value('general', 'op_nick') // 'chanserv';

    my $op_command = $self->{pbot}->{registry}->get_value($channel, 'op_command') // $self->{pbot}->{registry}->get_value('general', 'op_command') // "op $channel";

    $op_command =~ s/\$channel\b/$channel/g;

    if (not exists $self->{is_opped}->{$channel}) {
        $self->{pbot}->{conn}->privmsg($op_nick, $op_command);
        $self->{op_requested}->{$channel} = scalar gettimeofday;
    } else {
        $self->perform_op_commands($channel);
    }
}

sub lose_ops {
    my $self    = shift;
    my $channel = shift;
    $channel = lc $channel;
    $self->{pbot}->{conn}->mode($channel, '-o ' . $self->{pbot}->{registry}->get_value('irc', 'botnick'));
}

sub add_op_command {
    my ($self, $channel, $command) = @_;
    $channel = lc $channel;
    return if not $self->can_gain_ops($channel);
    push @{$self->{op_commands}->{$channel}}, $command;
}

sub perform_op_commands {
    my $self    = shift;
    my $channel = shift;
    $channel = lc $channel;
    my $botnick = $self->{pbot}->{registry}->get_value('irc', 'botnick');

    $self->{pbot}->{logger}->log("Performing op commands...\n");
    while (my $command = shift @{$self->{op_commands}->{$channel}}) {
        if ($command =~ /^mode (.*?) (.*)/i) {
            $self->{pbot}->{conn}->mode($1, $2);
            $self->{pbot}->{logger}->log("  executing mode $1 $2\n");
        } elsif ($command =~ /^kick (.*?) (.*?) (.*)/i) {
            $self->{pbot}->{conn}->kick($1, $2, $3) unless $1 =~ /^\Q$botnick\E$/i;
            $self->{pbot}->{logger}->log("  executing kick on $1 $2 $3\n");
        } elsif ($command =~ /^sl (.*)/i) {
            $self->{pbot}->{conn}->sl($1);
            $self->{pbot}->{logger}->log("  executing sl $1\n");
        }
    }
    $self->{pbot}->{logger}->log("Done.\n");
}

sub ban_user {
    my $self = shift;
    my ($mask, $channel, $immediately) = @_;
    $self->add_to_ban_queue($channel, 'b', $mask);
    if (not defined $immediately or $immediately != 0) { $self->check_ban_queue; }
}

sub get_bans {
    my ($self, $mask, $channel) = @_;
    my $masks;

    if ($mask !~ m/[!@\$]/) {
        my ($message_account, $hostmask) = $self->{pbot}->{messagehistory}->{database}->find_message_account_by_nick($mask);

        if (defined $hostmask) {
            my $nickserv = $self->{pbot}->{messagehistory}->{database}->get_current_nickserv_account($message_account);
            $masks = $self->{pbot}->{bantracker}->get_baninfo($hostmask, $channel, $nickserv);
        }

        my %akas = $self->{pbot}->{messagehistory}->{database}->get_also_known_as($mask);

        foreach my $aka (keys %akas) {
            next if $akas{$aka}->{type} == $self->{pbot}->{messagehistory}->{database}->{alias_type}->{WEAK};
            next if $akas{$aka}->{nickchange} == 1;

            my $b = $self->{pbot}->{bantracker}->get_baninfo($aka, $channel);
            if (defined $b) {
                $masks = {} if not defined $masks;
                push @$masks, @$b;
            }
        }
    }
    return $masks;
}

sub unmode_user {
    my ($self, $mask, $channel, $immediately, $mode) = @_;

    $mask    = lc $mask;
    $channel = lc $channel;
    $self->{pbot}->{logger}->log("Removing mode $mode from $mask in $channel\n");

    my $bans = $self->get_bans($mask, $channel);
    my %unbanned;

    if (not defined $bans) {
        my $baninfo = {};
        $baninfo->{banmask} = $mask;
        $baninfo->{type}    = '+' . $mode;
        push @$bans, $baninfo;
    }

    foreach my $baninfo (@$bans) {
        next if $baninfo->{type} ne '+' . $mode;
        next if exists $unbanned{$baninfo->{banmask}};
        $unbanned{$baninfo->{banmask}} = 1;
        $self->add_to_unban_queue($channel, $mode, $baninfo->{banmask});
    }
    $self->check_unban_queue if $immediately;
}

sub nick_to_banmask {
    my ($self, $mask) = @_;

    if ($mask !~ m/[!@\$]/) {
        my ($message_account, $hostmask) = $self->{pbot}->{messagehistory}->{database}->find_message_account_by_nick($mask);
        if (defined $hostmask) {
            my $nickserv = $self->{pbot}->{messagehistory}->{database}->get_current_nickserv_account($message_account);
            if (defined $nickserv && length $nickserv) { $mask = '$a:' . $nickserv; }
            else {
                my ($nick, $user, $host) = $hostmask =~ m/([^!]+)!([^@]+)@(.*)/;
                $mask = "*!$user\@" . $self->{pbot}->{antiflood}->address_to_mask($host);
            }
        } else {
            $mask .= '!*@*';
        }
    }
    return $mask;
}

sub unban_user {
    my ($self, $mask, $channel, $immediately) = @_;
    $mask    = lc $mask;
    $channel = lc $channel;
    $self->{pbot}->{logger}->log("Unbanning $channel $mask\n");
    $self->unmode_user($mask, $channel, $immediately, 'b');
}

sub ban_user_timed {
    my ($self, $owner, $reason, $mask, $channel, $length, $immediately) = @_;

    $channel = lc $channel;
    $mask    = lc $mask;

    $mask = $self->nick_to_banmask($mask);
    $self->ban_user($mask, $channel, $immediately);

    my $data = {};
    $data->{timeout} = $length > 0 ? gettimeofday + $length : -1;
    $data->{owner}   = $owner  if defined $owner;
    $data->{reason}  = $reason if defined $reason;
    $self->{unban_timeout}->add($channel, $mask, $data);

    $self->{pbot}->{timer}->dequeue_event("unban_timeout $channel $mask");

    if ($length > 0) {
        $self->enqueue_unban_timeout($channel, $mask, $length);
    }
}

sub checkban {
    my ($self, $channel, $target) = @_;
    my $mask = $self->nick_to_banmask($target);

    if ($self->{unban_timeout}->exists($channel, $mask)) {
        my $timeout = $self->{unban_timeout}->get_data($channel, $mask, 'timeout');
        my $owner   = $self->{unban_timeout}->get_data($channel, $mask, 'owner');
        my $reason  = $self->{unban_timeout}->get_data($channel, $mask, 'reason');
        my $duration = concise duration($timeout - gettimeofday);

        my $result = "$mask banned in $channel ";

        $result .= "by $owner "   if defined $owner;
        $result .= "for $reason " if defined $reason;
        $result .= $timeout > 0 ? "($duration remaining)" : "(permanent)";
        return $result;
    } else {
        return "$mask has no ban timeout.";
    }
}

sub mute_user {
    my $self = shift;
    my ($mask, $channel, $immediately) = @_;
    $self->add_to_ban_queue($channel, 'q', $mask);
    if (not defined $immediately or $immediately != 0) { $self->check_ban_queue; }
}

sub unmute_user {
    my ($self, $mask, $channel, $immediately) = @_;
    $mask    = lc $mask;
    $channel = lc $channel;
    $self->{pbot}->{logger}->log("Unmuting $channel $mask\n");
    $self->unmode_user($mask, $channel, $immediately, 'q');
}

sub mute_user_timed {
    my $self = shift;
    my ($owner, $reason, $mask, $channel, $length, $immediately) = @_;

    $mask = $self->nick_to_banmask($mask);
    $self->mute_user($mask, $channel, $immediately);

    my $data = {};
    $data->{timeout} = $length > 0 ? gettimeofday + $length : -1;
    $data->{owner}   = $owner  if defined $owner;
    $data->{reason}  = $reason if defined $reason;
    $self->{unmute_timeout}->add($channel, $mask, $data);

    $self->{pbot}->{timer}->dequeue_event("unmute_timeout $channel $mask");

    if ($length > 0) {
        $self->enqueue_unmute_timeout($channel, $mask, $length);
    }
}

sub checkmute {
    my ($self, $channel, $target) = @_;
    my $mask = $self->nick_to_banmask($target);

    if ($self->{unmute_timeout}->exists($channel, $mask)) {
        my $timeout = $self->{unmute_timeout}->get_data($channel, $mask, 'timeout');
        my $owner   = $self->{unmute_timeout}->get_data($channel, $mask, 'owner');
        my $reason  = $self->{unmute_timeout}->get_data($channel, $mask, 'reason');
        my $duration = concise duration($timeout - gettimeofday);

        my $result = "$mask muted in $channel ";

        $result .= "by $owner "   if defined $owner;
        $result .= "for $reason " if defined $reason;
        $result .= $timeout > 0 ? "($duration remaining)" : "(permanent)";

        return $result;
    } else {
        return "$mask has no mute timeout.";
    }
}

sub join_channel {
    my ($self, $channels) = @_;

    $self->{pbot}->{conn}->join($channels);

    foreach my $channel (split /,/, $channels) {
        $channel = lc $channel;
        $self->{pbot}->{event_dispatcher}->dispatch_event('pbot.join', {channel => $channel});

        delete $self->{is_opped}->{$channel};
        delete $self->{op_requested}->{$channel};

        if ($self->{pbot}->{channels}->{channels}->exists($channel) and $self->{pbot}->{channels}->{channels}->get_data($channel, 'permop')) { $self->gain_ops($channel); }

        $self->{pbot}->{conn}->mode($channel);
    }
}

sub part_channel {
    my ($self, $channel) = @_;
    $channel = lc $channel;
    $self->{pbot}->{event_dispatcher}->dispatch_event('pbot.part', {channel => $channel});
    $self->{pbot}->{conn}->part($channel);
    delete $self->{is_opped}->{$channel};
    delete $self->{op_requested}->{$channel};
}

sub has_ban_timeout {
    my ($self, $channel, $mask) = @_;
    return $self->{unban_timeout}->exists($channel, $mask);
}

sub has_mute_timeout {
    my ($self, $channel, $mask) = @_;
    return $self->{unmute_timeout}->exists($channel, $mask);
}

sub add_to_ban_queue {
    my ($self, $channel, $mode, $target) = @_;
    push @{$self->{ban_queue}->{$channel}->{$mode}}, $target;
    $self->{pbot}->{logger}->log("Added +$mode $target for $channel to ban queue.\n");
}

sub check_ban_queue {
    my $self = shift;

    my $MAX_COMMANDS = 4;
    my $commands     = 0;

    foreach my $channel (keys %{$self->{ban_queue}}) {
        my $done = 0;
        while (not $done) {
            my ($list, $count, $modes);
            $list  = '';
            $modes = '+';
            $count = 0;

            foreach my $mode (keys %{$self->{ban_queue}->{$channel}}) {
                while (@{$self->{ban_queue}->{$channel}->{$mode}}) {
                    my $target = pop @{$self->{ban_queue}->{$channel}->{$mode}};
                    $list  .= " $target";
                    $modes .= $mode;
                    last if ++$count >= $self->{pbot}->{ircd}->{MODES};
                }

                if (not @{$self->{ban_queue}->{$channel}->{$mode}}) { delete $self->{ban_queue}->{$channel}->{$mode}; }

                last if $count >= $self->{pbot}->{ircd}->{MODES};
            }

            if (not keys %{$self->{ban_queue}->{$channel}}) {
                delete $self->{ban_queue}->{$channel};
                $done = 1;
            }

            if ($count) {
                $self->add_op_command($channel, "mode $channel $modes $list");
                $self->gain_ops($channel);

                return if ++$commands >= $MAX_COMMANDS;
            }
        }
    }
}

sub add_to_unban_queue {
    my ($self, $channel, $mode, $target) = @_;
    if (not grep { $_ eq $target } @{$self->{unban_queue}->{$channel}->{$mode}}) {
        push @{$self->{unban_queue}->{$channel}->{$mode}}, $target;
        $self->{pbot}->{logger}->log("Added -$mode $target for $channel to unban queue.\n");
    }
}

sub check_unban_queue {
    my $self = shift;

    my $MAX_COMMANDS = 4;
    my $commands     = 0;

    foreach my $channel (keys %{$self->{unban_queue}}) {
        my $done = 0;
        while (not $done) {
            my ($list, $count, $modes);
            $list  = '';
            $modes = '-';
            $count = 0;

            foreach my $mode (keys %{$self->{unban_queue}->{$channel}}) {
                while (@{$self->{unban_queue}->{$channel}->{$mode}}) {
                    my $target = pop @{$self->{unban_queue}->{$channel}->{$mode}};
                    $list  .= " $target";
                    $modes .= $mode;
                    last if ++$count >= $self->{pbot}->{ircd}->{MODES};
                }

                if (not @{$self->{unban_queue}->{$channel}->{$mode}}) { delete $self->{unban_queue}->{$channel}->{$mode}; }

                last if $count >= $self->{pbot}->{ircd}->{MODES};
            }

            if (not keys %{$self->{unban_queue}->{$channel}}) {
                delete $self->{unban_queue}->{$channel};
                $done = 1;
            }

            if ($count) {
                $self->add_op_command($channel, "mode $channel $modes $list");
                $self->gain_ops($channel);

                return if ++$commands >= $MAX_COMMANDS;
            }
        }
    }
}

sub enqueue_unmute_timeout {
    my ($self, $channel, $hostmask, $interval) = @_;

    $self->{pbot}->{timer}->enqueue_event(
        sub {
            return if not $self->{pbot}->{joined_channels};
            $self->{pbot}->{timer}->update_interval("unmute_timeout $channel $hostmask", 60 * 15, 1); # try again in 15 minutes
            $self->unmute_user($hostmask, $channel);
        }, $interval, "unmute_timeout $channel $hostmask", 1
    );
}

sub enqueue_unban_timeout {
    my ($self, $channel, $hostmask, $interval) = @_;

    $self->{pbot}->{timer}->enqueue_event(
        sub {
            return if not $self->{pbot}->{joined_channels};
            $self->{pbot}->{timer}->update_interval("unban_timeout $channel $hostmask", 60 * 15, 1); # try again in 15 minutes
            $self->unban_user($hostmask, $channel);
        }, $interval, "unban_timeout $channel $hostmask", 1
    );
}

sub enqueue_unmute_timeouts {
    my ($self) = @_;
    my $now = time;

    foreach my $channel ($self->{unmute_timeout}->get_keys) {
        foreach my $mask ($self->{unmute_timeout}->get_keys($channel)) {
            my $timeout = $self->{unmute_timeout}->get_data($channel, $mask, 'timeout');
            next if $timeout <= 0;
            my $interval = $timeout - $now;
            $interval = 10 if $interval < 10;
            $self->enqueue_unmute_timeout($channel, $mask, $interval);
        }
    }
}

sub enqueue_unban_timeouts {
    my ($self) = @_;
    my $now = time;

    foreach my $channel ($self->{unban_timeout}->get_keys) {
        foreach my $mask ($self->{unban_timeout}->get_keys($channel)) {
            my $timeout = $self->{unban_timeout}->get_data($channel, $mask, 'timeout');
            next if $timeout <= 0;
            my $interval = $timeout - $now;
            $interval = 10 if $interval < 10;
            $self->enqueue_unban_timeout($channel, $mask, $interval);
        }
    }
}

sub enqueue_timeouts {
    my ($self) = @_;
    $self->enqueue_unmute_timeouts;
    $self->enqueue_unban_timeouts;
}

sub check_opped_timeouts {
    my $self = shift;
    my $now  = gettimeofday();
    foreach my $channel (keys %{$self->{is_opped}}) {
        if ($self->{is_opped}->{$channel}{timeout} < $now) {
            unless ($self->{pbot}->{channels}->{channels}->exists($channel) and $self->{pbot}->{channels}->{channels}->get_data($channel, 'permop')) { $self->lose_ops($channel); }
        }
    }

    foreach my $channel (keys %{$self->{op_requested}}) {
        if ($now - $self->{op_requested}->{$channel} > 60 * 5) {
            if ($self->{pbot}->{channels}->{channels}->exists($channel) and $self->{pbot}->{channels}->{channels}->get_data($channel, 'enabled')) {
                $self->{pbot}->{logger}->log("5 minutes since OP request for $channel and no OP yet; trying again ...\n");
                delete $self->{op_requested}->{$channel};
                $self->gain_ops($channel);
            } else {
                $self->{pbot}->{logger}->log("Disregarding OP request for $channel (channel is disabled)\n");
                delete $self->{op_requested}->{$channel};
            }
        }
    }
}

1;
