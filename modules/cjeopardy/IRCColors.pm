#!/usr/bin/env perl

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

use warnings;
use strict;

package IRCColors;

use Exporter;
our @ISA = 'Exporter';
our @EXPORT = qw(%color);

our %color = (
  white      => "\x0300",
  black      => "\x0301",
  blue       => "\x0302",
  green      => "\x0303",
  red        => "\x0304",
  maroon     => "\x0305",
  purple     => "\x0306",
  orange     => "\x0307",
  yellow     => "\x0308",
  lightgreen => "\x0309",
  teal       => "\x0310",
  cyan       => "\x0311",
  lightblue  => "\x0312",
  magneta    => "\x0313",
  gray       => "\x0314",
  lightgray  => "\x0315",

  bold       => "\x02",
  italics    => "\x1D",
  underline  => "\x1F",
  reverse    => "\x16",

  reset      => "\x0F",
);

1;
