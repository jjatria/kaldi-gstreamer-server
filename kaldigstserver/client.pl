#!/bin/env perl

use Modern::Perl '2015';
use autodie;

use Class::Load 'try_load_class';
use AnyEvent::WebSocket::Client;
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
$opt{url}      //= 'ws://localhost/client/ws/speech';
$opt{url}        = URI::ws->new($opt{url});
if (defined $opt{port}) {
  $opt{url}->port($opt{port});
}
else {
  $opt{port} = $opt{url}->port;
}

my $infile  = shift or die "Usage: $0 [options] file\n";
my $size = -s $infile;

my $client = AnyEvent::WebSocket::Client->new;

warn "Connecting to $opt{url}\n" if $opt{debug};

$client->connect($opt{url})->cb(sub {
  our $connection = eval { shift->recv };
  if ($@) {
    warn $@;
    return;
  };

  our @final;

  open ( my $fh, $infile ) or die "$infile: $!\n";
  my $buffer;
  while (read $fh, $buffer, $opt{byterate} / 4) {
    my $msg = AnyEvent::WebSocket::Message->new(
      body => $buffer,
      opcode => 2,
    );
    $connection->send($msg);
  }
  warn "Audio sent, now sending EOS\n";
  $connection->send('EOS');

  $connection->on(each_message => sub {
    my ($connection, $msg) = @_;

    use JSON;
    my $response = decode_json($msg->decoded_body);

    if ($opt{debug}) {
      use Data::Printer;
      p $response;
    }

    if ($response->{status} == 0) {
      my $transcript = $response->{result}->{hypotheses}->[0]->{transcript};
      $transcript =~ s%\n%\\n%g;
      if ($transcript) {
        local $| = 1;
        my $line;
        if (length($transcript) > $opt{width}) {
          my $rest = length $opt{line_prefix} - $opt{width};
          $line = sprintf("$opt{line_prefix}%s", substr($transcript, $rest));
        }
        else {
          $line = $transcript
        }
        print "\r", $line;
      }

      if ($response->{result}->{final}) {
        print "\r$transcript\n";
        push @final, $transcript;
      }
    }
    else {
      warn "Received error from server (status $response->{status})\n";
      if (defined $response->{message}) {
        warn "Error message: ", $response->{message}, "\n";
      }
    }
  });

  $connection->on(finish => sub {
    my ($connection) = @_;
    $connection->close;
    print join(' ', @final), "\n";
    exit;
  });
});

AnyEvent->condvar->recv;
