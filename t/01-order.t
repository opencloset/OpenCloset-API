use utf8;
use strict;
use warnings;

use DateTime;

use open ':std', ':encoding(utf8)';
use Test::More;

use OpenCloset::Constants::Status qw/$RENTABLE $RENTAL $BOXED $PAYMENT $RETURNED $CANCEL_BOX $PAYBACK/;
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

my $hostname = `hostname`;
my $username = $ENV{USER};

if ( $username eq 'opencloset' or $hostname =~ m/opencloset/ ) {
    plan skip_all => 'Do not run on service host';
}

my $api = OpenCloset::API::Order->new( schema => $schema, notify => 0 );
ok( $api, 'OpenCloset::API::Order->new' );

subtest '포장 -> 포장완료' => sub {
    my $order_param;
    $order_param = order_param($schema);
    $order_param->{user_id} = 2; # 3회 이상 대여자 id

    my $order = $schema->resultset('Order')->create($order_param);
    ok($order);

    my $user_info = $schema->resultset('UserInfo')->find( { user_id => 2 } );
    my $shoes = $schema->resultset('Clothes')->find( { code => '0A001' } );
    $user_info->update( { foot => $shoes->length + 10 } );

    #---------------------------------

    my @codes = qw/0A001 0S003 0P001 0J001/;
    @codes = $api->_sort_codes(@codes);
    is_deeply( \@codes, [qw/0J001 0P001 0S003 0A001/], '_sort_codes' );

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

    is( $rental_fee, 30_000,  '대여비: jacket,pants,shirt,shoes' );
    is( $discount,   -30_000, '단벌 할인쿠폰' );

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

subtest '포장완료 -> 결제대기' => sub {
    my $order_param = order_param($schema);
    $order_param->{user_id} = 2;

    my $order   = $schema->resultset('Order')->create($order_param);
    my @codes   = qw/0J001 0P001 0S003 0A001/;
    my $success = $api->box2boxed( $order, \@codes );
    $success = $api->boxed2payment($order);
    ok( $success, 'boxed2payment' );
    is( $order->status_id, $PAYMENT, 'status_id' );
};

subtest '결제대기 -> 대여중' => sub {
    my $order_param = order_param($schema);
    $order_param->{user_id} = 2;

    my $order = $schema->resultset('Order')->create($order_param);
    my @codes = qw/0J001 0P001 0S003 0A001/;
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);
    my $success = $api->payment2rental( $order, price_pay_with => '현금' );
    ok( $success, 'payment2rental' );
    is( $order->status_id, $RENTAL, 'status_id' );

    $order_param = order_param($schema);
    $order_param->{user_id} = 2;

    $order = $schema->resultset('Order')->create($order_param);
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);
    $success = $api->payment2rental( $order, price_pay_with => '카드', additional_day => 2 );

    my $today = DateTime->today( time_zone => 'Asia/Seoul' );
    my $user_target_date = $today->clone->add( days => 3 + 2 )->set( hour => 23, minute => 59, second => 59 );
    is( $order->additional_day, 2, 'additional_day' );
    is( $order->user_target_date->datetime, $user_target_date->datetime, 'user_target_date' );

    ## TODO: sms 내용 및 전송 여부
};

subtest '대여중 -> 반납' => sub {
    my $order_param = order_param($schema);
    $order_param->{user_id} = 2;

    my $order = $schema->resultset('Order')->create($order_param);
    my @codes = qw/0J001 0P001 0S003 0A001/;
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);
    $api->payment2rental( $order, price_pay_with => '현금' );
    my $success = $api->rental2returned($order);
    ok( $success, 'rental2returned' );
    is( $order->status_id, $RETURNED, 'status_id' );

    my $is_returned;

    my $details = $order->order_details( { clothes_code => { '!=' => undef } } );
    while ( my $detail = $details->next ) {
        $is_returned = $detail->status_id == $RETURNED;
    }
    ok( $is_returned, 'order_detail.status_id' );

    my $clothes = $order->clothes;
    while ( my $c = $clothes->next ) {
        $is_returned = $c->status_id == $RETURNED;
    }
    ok( $is_returned, 'clothes.status_id' );

    $order = $schema->resultset('Order')->create($order_param);
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);
    $api->payment2rental( $order, price_pay_with => '현금' );

    my $target_date      = $order->target_date;
    my $user_target_date = $target_date->clone->add( days => 2 );
    my $return_date      = $user_target_date->clone->add( days => 2 );
    $order->update( { user_target_date => $user_target_date->datetime } );

    $success = $api->rental2returned(
        $order,
        return_date           => $return_date,
        late_fee_pay_with     => '현금',
        late_fee_discount     => 1000,
        compensation_pay_with => '카드',
        compensation_price    => 2000,
        compensation_discount => 1000,
    );

    ok( $success, 'rental2returned' );
    is( $order->late_fee_pay_with,     '현금', 'late_fee_pay_with' );
    is( $order->compensation_pay_with, '카드', 'compensation_pay_with' );

    $details = $order->order_details;
    ok( $details->search( { name => '연장료' } )->next,                  '연장료' );
    ok( $details->search( { name => '연체료' } )->next,                  '연체료' );
    ok( $details->search( { name => '연체/연장료 에누리' } )->next, '연체/연장료 에누리' );
    ok( $details->search( { name => '배상비' } )->next,                  '배상비' );
    ok( $details->search( { name => '배상비 에누리' } )->next,        '배상비 에누리' );
};

subtest 'additional_day' => sub {
    my $order_param = order_param($schema);
    $order_param->{user_id} = 2;

    my $order = $schema->resultset('Order')->create($order_param);
    my @codes = qw/0J001 0P001 0S003 0A001/;
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);

    ## 반납희망일은 반납예정일 + additional_day
    my $user_target_date = $order->target_date->clone;

    my $success = $api->additional_day( $order, 1 );

    ok( $success, 'additional_day' );
    is( $order->additional_day, 1, 'order->additional_day' );

    my $detail = $order->order_details( { clothes_code => '0J001' } )->next;
    is( $detail->final_price, 12_000, 'order_detail.final_price' );
    is( $order->user_target_date->datetime, $user_target_date->add( days => 1 )->datetime, 'user_target_date' );
};

subtest 'rental2partial_returned' => sub {
    my $order_param = order_param($schema);
    $order_param->{user_id} = 2;

    my $order = $schema->resultset('Order')->create($order_param);
    my @codes = qw/0J001 0P001 0S003 0A001/;
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);
    $api->payment2rental( $order, price_pay_with => '현금' );
    my $success = $api->rental2partial_returned( $order, [qw/0J001 0P001 0S003/] );
    ok( $success, 'rental2partial_returned' );
    is( $order->status_id, $RETURNED, 'order.status_id' );
    my $child = $order->orders->next;
    ok( $child, 'child order' );
    is( $child->status_id, $PAYMENT, 'child.status_id' );
    my $detail = $child->order_details->next;
    ok( $detail, 'child.order_details' );
    is( $detail->clothes_code, '0A001', 'child.clothes_code' );
};

subtest 'payment2box' => sub {
    my $order_param = order_param($schema);
    $order_param->{user_id} = 2;

    my $order = $schema->resultset('Order')->create($order_param);
    my @codes = qw/0J001 0P001 0S003 0A001/;
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);

    my $success = $api->payment2box($order);
    ok( $success, 'payment2box' );
    my $clothes = $schema->resultset('Clothes')->find( { code => '0J001' } );
    is( $clothes->status_id, $CANCEL_BOX, 'clothes.status_id' );
    my $count = $order->order_details->count;
    is( $count,                   0,     'deleted order_details' );
    is( $order->rental_date,      undef, 'rental_date' );
    is( $order->target_date,      undef, 'target_date' );
    is( $order->user_target_date, undef, 'user_target_date' );
    is( $order->return_date,      undef, 'return_date' );
    is( $order->price_pay_with,   undef, 'price_pay_with' );
};

subtest 'rental2payback' => sub {
    my $order_param = order_param($schema);
    $order_param->{user_id} = 2;

    my $order = $schema->resultset('Order')->create($order_param);
    my @codes = qw/0J001 0P001 0S003 0A001/;
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);
    $api->payment2rental( $order, price_pay_with => '현금' );
    my $success = $api->rental2payback($order);
    ok( $success, 'rental2payback' );
    my $detail = $order->order_details( { name => '환불' } )->next;
    ok( $detail, 'added order_detail' );

    my $calc         = OpenCloset::Calculator::LateFee->new;
    my $rental_price = $calc->rental_price($order);
    is( $detail->final_price, $rental_price * -1, 'final_price' );

    is( $order->status_id, $PAYBACK, 'order.status_id' );
    my $clothes = $order->clothes->next;
    is( $clothes->status_id, $PAYBACK, 'clothes.status_id' );

    my $coupon_param = coupon_param( $schema, 'default' );
    my $coupon = $schema->resultset('Coupon')->create($coupon_param);

    $order_param              = order_param($schema);
    $order_param->{user_id}   = 2;
    $order_param->{coupon_id} = $coupon->id;
    $order                    = $schema->resultset('Order')->create($order_param);
    $api->box2boxed( $order, \@codes );
    $api->boxed2payment($order);
    $api->payment2rental( $order, price_pay_with => '쿠폰' );
    is( $order->coupon->status, 'used', 'coupon state is changed to used' );
    $success = $api->rental2payback($order);
    ok( $success, 'rental2payback with coupon' );
    is( $order->coupon->status, 'reserved', 'coupon state is changed to reserved' );
};

done_testing();
