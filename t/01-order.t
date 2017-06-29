use utf8;
use strict;
use warnings;

use open ':std', ':encoding(utf8)';
use Test::More;

use OpenCloset::Constants::Status qw/$RENTABLE $BOXED $PAYMENT/;
use OpenCloset::Schema;
use OpenCloset::Calculator::LateFee;

use OpenCloset::API::Order;

use lib 't/lib';
use Param::Order qw/order_param/;
use Param::Coupon qw/coupon_param/;

my $db_opts = {
    dsn  => $ENV{OPENCLOSET_DATABASE_DSN}  || "dbi:mysql:opencloset:127.0.0.1",
    user => $ENV{OPENCLOSET_DATABASE_USER} || 'opencloset',
    password => $ENV{OPENCLOSET_DATABASE_PASS} // 'opencloset',
    quote_char        => q{`},
    mysql_enable_utf8 => 1,
    on_connect_do     => 'SET NAMES utf8',
    RaiseError        => 1,
    AutoCommit        => 1,
};

my $schema = OpenCloset::Schema->connect($db_opts);

subtest '포장 -> 포장완료' => sub {
    my $api = OpenCloset::API::Order->new( schema => $schema, notify => 0 );
    ok( $api, 'OpenCloset::API::Order->new' );

    my $order_param;
    $order_param = order_param($schema);
    $order_param->{user_id} = 2; # 3회 이상 대여자 id

    my $order = $schema->resultset('Order')->create($order_param);
    ok($order);

    my $user_info = $schema->resultset('UserInfo')->find( { user_id => 2 } );
    my $shoes = $schema->resultset('Clothes')->find( { code => '0A001' } );
    $user_info->update( { foot => $shoes->length + 10 } );

    #---------------------------------

    my @codes = qw/0J001 0P001 0S003 0A001/;
    my $clothes = $schema->resultset('Clothes')->search( { code => { -in => \@codes } } );
    $clothes->update_all( { status_id => $RENTABLE } );

    my $success = $api->box2boxed( $order, \@codes );

    ok( $success, 'box2boxed' );
    is( $order->status_id, $BOXED, 'status_id' );
    my $is_payment;
    while ( my $c = $clothes->next ) {
        $is_payment = $c->status_id == $PAYMENT;
    }

    ok( $is_payment, 'all clothes status' );

    ## $user_info->update(\%columns) will not run any update triggers
    $user_info = $schema->resultset('UserInfo')->find( { user_id => 2 } );
    is( $user_info->foot, $shoes->length, 'user_info.foot == shoes.length' );

    my $calc       = OpenCloset::Calculator::LateFee->new;
    my $rental_fee = $calc->price($order);
    my $discount   = $calc->discount_price($order);

    is( $rental_fee, 30_000,  '대여비: jacket,pants,shirt,shoes' );
    is( $discount,   -10_000, '3회 이상 대여 - 3회 이상 방문(셋트 이외 무료)' );

    my $user = $schema->resultset('User')->find( { id => 3 } );
    $user->delete_related('orders');
    $order_param = order_param($schema);
    $order_param->{user_id} = $user->id;

    $order = $schema->resultset('Order')->create($order_param);
    ok($order);

    $success = $api->box2boxed( $order, \@codes );

    ok( $success, 'box2boxed' );

    $rental_fee = $calc->price($order);
    $discount   = $calc->discount_price($order);

    is( $rental_fee, 30_000, '대여비: jacket,pants,shirt,shoes' );
    is( $discount,   0,      '할인 대상 아님' );

    my $coupon_param = coupon_param( $schema, 'default' );
    my $coupon = $schema->resultset('Coupon')->create($coupon_param);

    $order_param              = order_param($schema);
    $order_param->{user_id}   = 2;
    $order_param->{coupon_id} = $coupon->id;
    $order                    = $schema->resultset('Order')->create($order_param);

    $success = $api->box2boxed( $order, \@codes );

    ok( $success, 'box2boxed' );

    $rental_fee = $calc->price($order);
    $discount   = $calc->discount_price($order);

    is( $rental_fee, 30_000,  '대여비: jacket,pants,shirt,shoes' );
    is( $discount,   -13_000, '금액 할인쿠폰' );

    $coupon_param = coupon_param( $schema, 'suit' );
    $coupon = $schema->resultset('Coupon')->create($coupon_param);

    $order_param              = order_param($schema);
    $order_param->{user_id}   = 2;
    $order_param->{coupon_id} = $coupon->id;
    $order                    = $schema->resultset('Order')->create($order_param);

    $success = $api->box2boxed( $order, \@codes );

    ok( $success, 'box2boxed' );

    $rental_fee = $calc->price($order);
    $discount   = $calc->discount_price($order);

    is( $rental_fee, 30_000, '대여비: jacket,pants,shirt,shoes' );

    ## 단벌 할인쿠폰은 대여비를 기준으로 연체/연장비를 지급받음
    ## 그래서 할인금액이 -30_000 이 아니라 0
    is( $discount, 0, '단벌 할인쿠폰' );

    $coupon_param = coupon_param( $schema, 'rate' );
    $coupon = $schema->resultset('Coupon')->create($coupon_param);

    $order_param              = order_param($schema);
    $order_param->{user_id}   = 2;
    $order_param->{coupon_id} = $coupon->id;
    $order                    = $schema->resultset('Order')->create($order_param);

    $success = $api->box2boxed( $order, \@codes );

    ok( $success, 'box2boxed' );

    $rental_fee = $calc->price($order);
    $discount   = $calc->discount_price($order);

    is( $rental_fee, 30_000, '대여비: jacket,pants,shirt,shoes' );

    is( $discount, -9_000, '비율 할인쿠폰' );
    ok( $order->order_details( { name => '배송비' } )->next, '배송비' );
    ok( $order->order_details( { name => '에누리' } )->next, '에누리' );
};

done_testing();
