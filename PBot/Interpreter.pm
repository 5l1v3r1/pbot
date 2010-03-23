# File: Interpreter.pm
# Author: pragma_
#
# Purpose: 

package PBot::Interpreter;

use warnings;
use strict;

use base 'PBot::Registerable';

use Carp ();

BEGIN {
  use vars qw($VERSION);
  $VERSION = '1.0.0';
}

sub new {
  if(ref($_[1]) eq 'HASH') {
    Carp::croak("Options to Interpreter should be key/value pairs, not hash reference");
  }

  my ($class, %conf) = @_;

  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;

  $self->SUPER::initialize(%conf);

  my $pbot = delete $conf{pbot};

  if(not defined $pbot) {
    Carp::croak("Missing pbot reference to PBot::Interpreter");
  }

  $self->{pbot} = $pbot;
}

sub process_line {
  my $self = shift;
  my ($from, $nick, $user, $host, $text) = @_;
  
  my ($command, $args, $result);
  my $has_url = undef;
  my $mynick = $self->pbot->botnick;

  $from = lc $from if defined $from;

  my $pbot = $self->pbot;

  $pbot->antiflood->check_flood($from, $nick, $user, $host, $text, $pbot->{MAX_FLOOD_MESSAGES}, $pbot->{FLOOD_CHAT}) if defined $from;

  if($text =~ /^.?$mynick.?\s+(.*?)([\?!]*)$/i) {
    $command = "$1";
  } elsif($text =~ /^(.*?),?\s+$mynick([\?!]*)$/i) {
    $command = "$1";
  } elsif($text =~ /^!(.*?)(\?*)$/) {
    $command = "$1";
  } elsif($text =~ /http:\/\/([^\s]+)/i) {
    $has_url = $1;
  }

  if(defined $command || defined $has_url) {
    if((defined $command && $command !~ /^login/i) || defined $has_url) {
      if(defined $from && $pbot->ignorelist->check_ignore($nick, $user, $host, $from) && not $pbot->admins->loggedin($from, "$nick!$user\@$host")) {
        # ignored hostmask
        $pbot->logger->log("ignored text: [$from][$nick!$user\@$host\[$text\]\n");
        return;
      }
    }

    if(not defined $has_url) {
      $result = $self->interpret($from, $nick, $user, $host, 1, $command);
    } else {
      $result = $self->{pbot}->factoids->{factoidmodulelauncher}->execute_module($from, undef, $nick, $user, $host, "title", "$nick http://$has_url");
    }
    
    $result =~ s/\$nick/$nick/g if defined $result;

    # TODO add paging system?
    if(defined $result && length $result > 0) {
      my $len = length $result;
      if($len > $pbot->max_msg_len) {
        if(($len - $pbot->max_msg_len) > 10) {
          $pbot->logger->log("Message truncated.\n");
          $result = substr($result, 0, $pbot->max_msg_len);
          substr($result, $pbot->max_msg_len) = "... (" . ($len - $pbot->max_msg_len) . " more characters)";
        }
      }

      $pbot->logger->log("Final result: $result\n");
      
      if($result =~ s/^\/me\s+//i) {
        $pbot->conn->me($from, $result) if defined $from && $from !~ /\Q$mynick\E/i;
      } elsif($result =~ s/^\/msg\s+([^\s]+)\s+//i) {
        my $to = $1;
        if($to =~ /.*serv$/i) {
          $pbot->logger->log("[HACK] Possible HACK ATTEMPT /msg *serv: [$nick!$user\@$host] [$command] [$result]\n");
        }
        elsif($result =~ s/^\/me\s+//i) {
          $pbot->conn->me($to, $result) if $to !~ /\Q$mynick\E/i;
        } else {
          $result =~ s/^\/say\s+//i;
          $pbot->conn->privmsg($to, $result) if $to !~ /\Q$mynick\E/i;
        }
      } else {
        $pbot->conn->privmsg($from, $result) if defined $from && $from !~ /\Q$mynick\E/i;
      }
    }
    $pbot->logger->log("---------------------------------------------\n");

    # TODO: move this to FactoidModuleLauncher somehow, completely out of Interpreter!
    if($pbot->factoids->{factoidmodulelauncher}->{child} != 0) {
      # if this process is a child, it must die now
      $pbot->logger->log("Terminating module.\n");
      exit 0;
    }
  }
}

sub interpret {
  my $self = shift;
  my ($from, $nick, $user, $host, $count, $command) = @_;
  my ($keyword, $arguments, $tonick);
  my $text;
  my $pbot = $self->pbot;

  $pbot->logger->log("=== Enter interpret_command: [" . (defined $from ? $from : "(undef)") . "][$nick!$user\@$host][$count][$command]\n");

  return "Too many levels of recursion, aborted." if(++$count > 5);

  if(not defined $nick || not defined $user || not defined $host ||
     not defined $command) {
    $pbot->logger->log("Error 1, bad parameters to interpret_command\n");
    return undef;
  }

  if($command =~ /^tell\s+(.{1,20})\s+about\s+(.*?)\s+(.*)$/i) 
  {
    ($keyword, $arguments, $tonick) = ($2, $3, $1);
  } elsif($command =~ /^tell\s+(.{1,20})\s+about\s+(.*)$/) {
    ($keyword, $tonick) = ($2, $1);
  } elsif($command =~ /^([^ ]+)\s+is\s+also\s+(.*)$/) {
    ($keyword, $arguments) = ("change", "$1 s,\$, ; $2,");
  } elsif($command =~ /^([^ ]+)\s+is\s+(.*)$/) {
    ($keyword, $arguments) = ("add", join(' ', $1, $2)) unless exists ${ $pbot->factoids }{$1};
    ($keyword, $arguments) = ($1, "is $2") if exists ${ $pbot->factoids }{$1};
  } elsif($command =~ /^(.*?)\s+(.*)$/) {
    ($keyword, $arguments) = ($1, $2);
  } else {
    $keyword = $1 if $command =~ /^(.*)$/;
  }
  
  $arguments =~ s/\bme\b/\$nick/gi if defined $arguments;
  $arguments =~ s/\/\$nick/\/me/gi if defined $arguments;

  $pbot->logger->log("keyword: [$keyword], arguments: [" . (defined $arguments ? $arguments : "(undef)") . "], tonick: [" . (defined $tonick ? $tonick : "(undef)") . "]\n");

  if(defined $arguments && $arguments =~ m/\b(your|him|her|its|it|them|their)(self|selves)\b/i) {
    return "Why would I want to do that to myself?";
  }

  if(not defined $keyword) {
    $pbot->logger->log("Error 2, no keyword\n");
    return undef;
  }

  return $self->SUPER::execute_all($from, $nick, $user, $host, $count, $keyword, $arguments, $tonick);
}

sub pbot {
  my $self = shift;
  if(@_) { $self->{pbot} = shift; }
  return $self->{pbot};
}

1;
