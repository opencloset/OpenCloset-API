package Param::Coupon;
require Exporter;
@ISA       = qw(Exporter);
@EXPORT_OK = qw(coupon_param);

use strict;
use warnings;
use Algorithm::CouponCode qw/cc_generate/;
use DateTime;

sub coupon_param {
    my ( $schema, $type ) = @_;
    $type = 'suit' unless $type;

    my $price;
    if ( $type eq 'suit' ) {
        $price = 0;
    }
    elsif ( $type eq 'rate' ) {
        $price = 30;
    }
    else {
        $price = 13_000;
    }

    my $now = DateTime->now( time_zone => 'Asia/Seoul' );

    return {
        code         => cc_generate( parts => 3 ),
        type         => $type,
        status       => 'provided',
        desc         => 'test',
        extra        => undef,
        price        => $price,
        create_date  => $now->datetime,
        update_date  => $now->datetime,
        expires_date => undef,
    };
}

1;
