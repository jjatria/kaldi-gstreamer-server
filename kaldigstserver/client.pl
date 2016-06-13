#!/usr/bin/env perl

use Mojolicious::Lite;
use Data::Printer;
use Class::Load 'try_load_class';
use URI::ws;
use Getopt::Long;

my %opt;
GetOptions(
  \%opt,
  'url|u=s',
  'port|p=i',
  'byterate|r=i',
  'width|w=i',
  'debug|D',
);

$opt{line_prefix} = '... ';
if (try_load_class 'Term::ReadKey') {
  my @ret = Term::ReadKey::GetTerminalSize();
  $opt{width}  //= shift @ret;
}
else {
  $opt{width}  //= 80;
}
$opt{byterate} //= 32000;
$opt{debug}    //= 0;
$opt{url}      //= 'ws://localhost:8890/client/ws/speech';
$opt{url}        = URI::ws->new($opt{url});
if (defined $opt{port}) {
  $opt{url}->port($opt{port});
}
else {
  $opt{port} = $opt{url}->port;
}

my $infile  = shift or die "Usage: $0 [options] file\n";
my $size = -s $infile;

my $ua = Mojo::UserAgent->new;

my @final;

$ua->websocket("$opt{url}" => ['v1.proto'] => sub {
  my ($ua, $tx) = @_;
  say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
#   say 'Subprotocol negotiation failed!' and return unless $tx->protocol;

  $tx->on(finish => sub {
    my ($tx, $code, $reason) = @_;
    say "WebSocket closed with status $code.";
  });
  $tx->on(json => sub {
    my ($tx, $res) = @_;

    if ($res->{status} == 0) {
      my $transcript = $res->{result}->{hypotheses}->[0]->{transcript};
      $transcript =~ s%\n%\\n%g if defined $transcript;
      if ($transcript) {
        local $| = 1;
        my $line;
        if (length($transcript) >= $opt{width}) {
          my $rest = length($opt{line_prefix}) - $opt{width};
          $line = sprintf("$opt{line_prefix}%s", substr($transcript, $rest));
        }
        else {
          $line = $transcript
        }
        print "\r", $line;
      }
# 
      if ($res->{result}->{final}) {
        print "\r$transcript\n";
        push @final, $transcript;
      }
    }
    else {
      warn "Received error from server (status $res->{status})\n";
      if (defined $res->{message}) {
        warn "Error message: ", $res->{message}, "\n";
      }
    }
  });

  open ( my $fh, $infile ) or die "$infile: $!\n";
  my $buffer;
  while (read $fh, $buffer, $opt{byterate} / 4) {
    $tx->send({binary => $buffer});
  }
  warn "Audio sent, now sending EOS\n";
  $tx->send('EOS');
});
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
