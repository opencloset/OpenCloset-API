package Param::Order;
require Exporter;
@ISA       = qw(Exporter);
@EXPORT_OK = qw(order_param);

use strict;
use warnings;
use DateTime;

use OpenCloset::Constants::Status qw/$BOX/;

sub order_param {
    my $schema = shift;

    my $now = DateTime->now( time_zone => 'Asia/Seoul' );
    my $today = $now->clone->truncate( to => 'day' );
    my $booking_date = $today->clone->set( hour => 10 );
    my $booking = $schema->resultset('Booking')->find_or_create(
        {
            date   => "$booking_date",
            gender => 'male',
            slot   => 4,
        }
    );

    return {
        user_id               => undef,
        status_id             => $BOX,
        staff_id              => 2,
        parent_id             => undef,
        booking_id            => $booking->id,
        coupon_id             => undef,
        user_address_id       => undef,
        online                => 0,
        additional_day        => 0,
        rental_date           => undef,
        wearon_date           => $today->clone->add( days => 1 )->datetime,
        target_date           => $today->clone->add( days => 3 )->set( hour => 23, minute => 59, second => 59 )->datetime,
        user_target_date      => $today->clone->add( days => 3 )->set( hour => 23, minute => 59, second => 59 )->datetime,
        return_date           => undef,
        return_method         => undef,
        return_memo           => undef,
        price_pay_with        => undef,
        late_fee_pay_with     => undef,
        compensation_pay_with => undef,
        pass                  => undef,
        desc                  => undef,
        message               => undef,
        misc                  => undef,
        shipping_misc         => undef,
        purpose               => '입사면접',
        purpose2              => undef,
        pre_category          => 'jacket,pants,shirt,shoes',
        pre_color             => 'black',
        height                => 180,
        weight                => 70,
        neck                  => undef,
        bust                  => 89,
        waist                 => 82,
        hip                   => undef,
        topbelly              => 79,
        belly                 => undef,
        thigh                 => 53,
        arm                   => 62,
        leg                   => 99,
        knee                  => undef,
        foot                  => 270,
        pants                 => undef,
        skirt                 => undef,
        bestfit               => undef,
        ignore                => undef,
        ignore_sms            => undef,
        create_date           => $now->datetime,
        update_date           => $now->datetime,
        does_wear             => undef,
    };
}

1;
