# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

# Just a quick interface to test/play with PBot::Utils::ParseDate

package Plugins::ParseDate;
use parent 'Plugins::Plugin';

use warnings; use strict;
use feature 'unicode_strings';

use Time::Duration qw/duration/;

sub initialize {
    my ($self, %conf) = @_;
    $self->{pbot}->{commands}->register(sub { return $self->pd(@_) }, "pd", 0);
}

sub unload {
    my $self = shift;
    $self->{pbot}->{commands}->unregister("pd");
}

sub pd {
    my $self = shift;
    my ($from, $nick, $user, $host, $arguments) = @_;
    my ($seconds, $error) = $self->{pbot}->{parsedate}->parsedate($arguments);
    return $error if defined $error;
    return duration $seconds;
}

1;
