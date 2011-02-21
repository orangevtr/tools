#!/usr/bin/env perl

use strict;
use warnings;

use AnyEvent;
use AnyEvent::HTTP;
#use Data::Dumper;
use Time::HiRes qw(time);

use Getopt::Long;

my $concurrency = 10;
my $requests    = 100;

GetOptions( 'c=i' => \$concurrency, 'n=i' => \$requests );

my $URL = shift @ARGV;    # e.g. http://yahoo.co.jp/

die "usage: $0 [ -c <cuncurrency> ] [ -n <maxrequests> ] url" unless $URL;

main( $concurrency, $requests );

sub main {
    my ( $cur, $num ) = @_;
    my $main_cv = AnyEvent->condvar;

    my %records = ();

    for ( 1 .. $cur ) {
        $main_cv->begin();
        my $cv = _request_event( $_ => \%records );
        $cv->cb( _request_event_cb( $main_cv, $num, \%records ) );
    }

    print "% started at: " . time . "\n";

    $main_cv->recv();    # wait all requests
#    print Dumper \%records;

    print "% finished at: " . time . "\n";

    # 別途集計のため結果出力する
    print "% "
        . join( "\t",
        $_,
        map { defined $_ ? $_ : 'UNDEF' }
            @{ $records{$_} }
            {qw(worker_id code size prepared_at responsed_at url)} )
        . "\n"
        for keys %records;
}

sub _request_event {
    my ($worker_id, $records) = @_;

    my $cv = AnyEvent->condvar;
    my $id = scalar( keys %$records ) + 1;
    my ( $url, $headers ) = _create_request();
    $records->{$id} = { url => $url, headers => $headers };
    my $w;
    $w = AnyEvent->timer(
        after => 0,
        cb    => sub {
            http_get(
                $url,
                headers    => $headers,
                timeout    => 1,
                on_prepare => sub {
                    $records->{$id}->{prepared_at} = time;
                    $records->{$id}->{worker_id}   = $worker_id;
                },
                sub {
                    my ( $data, $headers ) = @_;
                    #warn join( " | ", $data, Dumper $headers);
                    $cv->send( $id, $headers->{Status}, length($data) );
                }
            );
            undef $w;    # このウォッチャー自体は１回限り
        },
    );

    return $cv;
}

sub _request_event_cb {
    my ( $main_cv, $max, $records ) = @_;

    # レコードして、回数インクリメントして
    sub {
        my ( $id, $code, $size ) = $_[0]->recv;
        my $r = $records->{$id};
        $r->{code}         = $code;
        $r->{size}         = $size;
        $r->{responsed_at} = time;
        if ( keys %$records < $max ) {

      # $numに到達してなければ再度タイマーウォッチャ発行
            my $cv = _request_event($r->{worker_id}, $records);
            $cv->cb( _request_event_cb( $main_cv, $max, $records ) );
        }
        else {

            # $numに到達してたら$cv->end();
            #warn "main_cv->end()";
            $main_cv->end();
        }
    };
}

# リクエスト用URLを作成する
# その気になればランダムに
sub _create_request {
    my %headers = (
        'User-Agent' =>
            'KDDI-CA3E UP.Browser/6.2_7.2.7.1.K.2.231 (GUI) MMP/2.0',
        'Client-Ip'  => '111.86.142.195',
        'X-Up-Subno' => '05001010123456_ad.ezweb.ne.jp',
    );

    return ( $URL, \%headers );
}
