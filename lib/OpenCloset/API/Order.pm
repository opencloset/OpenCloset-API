package OpenCloset::API::Order;

use utf8;
use strict;
use warnings;

use DateTime;
use HTTP::Tiny;
use Mojo::Loader qw/data_section/;
use Mojo::Template;
use Try::Tiny;

use OpenCloset::API::SMS;
use OpenCloset::Calculator::LateFee;
use OpenCloset::Constants::Category;
use OpenCloset::Constants::Status qw/$RENTAL $BOX $BOXED $PAYMENT $RETURNED/;

use OpenCloset::DB::Plugin::Order::Sale;

=encoding utf8

=head1 NAME

OpenCloset::API::Order - 주문서의 상태변경 API

=head1 SYNOPSIS

    my $api = OpenCloset::API::Order->new(schema => $schema);
    $api->box2boxed($order, ['J001', 'P001']);    # 포장 -> 포장완료
    $api->boxed2payment($order);                  # 포장완료 -> 결제대기
    $api->payment2rental($order, '현금');          # 결제대기 -> 대여중

=cut

our $MONITOR_HOST = $ENV{OPENCLOSET_MONITOR_HOST} || "https://monitor.theopencloset.net";

=head1 METHODS

=head2 new

    my $api = OpenCloset::API::Order->new(schema => $schema);

=over

=item *

schema - S<OpenCloset::Schema>

=item *

notify - Boolean

monitor 서비스로 상태변경 event 를 알립니다.
default 는 true 입니다.

=item *

sms - Boolean

사용자에게 상태에 따라 SMS 를 전송합니다.
default 는 true 입니다.

=back

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = {
        schema => $args{schema},
        notify => $args{notify} // 1,
        sms    => $args{sms} // 1,
        http   => HTTP::Tiny->new(
            timeout         => 3,
            default_headers => {
                agent        => __PACKAGE__,
                content_type => 'application/json',
            }
        ),
    };

    bless $self, $class;
    return $self;
}

=head2 box2boxed( $order, \@codes )

B<포장> -> B<포장완료>

    my $success = $api->box2boxed($order, ['J001', 'P001']);

=over

=item *

주문서의 상태를 C<$BOXED> 로 변경

=item *

의류의 상태를 C<$PAYMENT> 로 변경

=item *

각 의류별 주문서 상세항목을 추가

=item *

사용자의 구두 사이즈를 의류의 구두 사이즈로 변경

=item *

3회 이상 대여자 할인 및 쿠폰 할인

=item *

배송비(C<0>)와 에누리(C<0>) 추가

=item *

opencloset/monitor 에 event 를 posting

=back

=cut

sub box2boxed {
    my ( $self, $order, $codes ) = @_;
    return unless $order;
    return unless @{ $codes ||= [] };

    my @codes = map { sprintf( '%05s', $_ ) } @$codes;

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;

    my ( $success, $error ) = try {
        $order->update( { status_id => $BOXED } );

        my @order_details;
        for my $code (@codes) {
            my $clothes = $schema->resultset('Clothes')->find( { code => $code } );
            die "Not found clothes: $code" unless $clothes;

            my ($trim_code) = $code =~ s/^0//r;
            my $category = $clothes->category;
            my $name = join( q{ - }, $trim_code, $OpenCloset::Constants::Category::LABEL_MAP{$category} );
            $clothes->update( { status_id => $PAYMENT } );

            ## 3회 이상 대여 할인 대상자의 경우 가격이 변경되기 때문에 미리 넣으면 아니됨
            push @order_details, {
                clothes_code     => $code,
                clothes_category => $clothes->category,
                status_id        => $PAYMENT,
                name             => $name,
                price            => $clothes->price,
                final_price      => $clothes->price,
            };

            ## 사용자의 구두 사이즈를 주문서의 구두 사이즈로 변경 (#1251)
            next unless $code =~ m/^0A/;
            my $user_info = $order->user->user_info;
            my $foot      = $user_info->foot;
            my $length    = $clothes->length;
            if ( $foot and $length and $foot != $length ) {
                $user_info->update( { foot => $length } );
            }
        }

        ## 3회 이상 대여자 할인 또는 쿠폰 할인
        ## 결제대기 상태에서 쿠폰을 삽입하면 3회 이상 대여자의 중복할인을 제거해야 한다
        if ( my $coupon = $order->coupon ) {
            ## 쿠폰할인(가격, 비율, 단벌)
            ##   할인명목의 품목이 추가되는 방식(할인쿠폰: -10,000원)
            my $price_pay_with = '쿠폰';
            my $type           = $coupon->type;
            if ( $type eq 'default' ) {
                $price_pay_with .= '+';
                my $price = $coupon->price;
                push @order_details, {
                    name        => sprintf( "%s원 할인쿠폰", $self->commify($price) ),
                    price       => $price * -1,
                    final_price => $price * -1,
                };
            }
            elsif ( $type =~ m/(rate|suit)/ ) {
                my $price = 0;
                $price += $_->{price} for @order_details;

                if ( $type eq 'rate' ) {
                    my $rate = $coupon->price;
                    $price_pay_with .= '+';
                    push @order_details, {
                        name        => sprintf( "%d%% 할인쿠폰", $rate ),
                        price       => ( $price * $rate / 100 ) * -1,
                        final_price => ( $price * $rate / 100 ) * -1,
                    };
                }
                elsif ( $type eq 'suit' ) {
                    push @order_details, {
                        name        => '단벌 할인쿠폰',
                        price       => $price * -1,
                        final_price => $price * -1,
                    };
                }
            }

            $order->update( { price_pay_with => $price_pay_with } );
        }
        else {
            ## 3회 이상 대여 할인
            ##   의류 품목에서 할인금액이 차감되는 방식(자켓: 10,000 -> 7,000)
            my $sale_price = {
                before                => 0,
                after                 => 0,
                rented_without_coupon => 0,
            };

            $sale_price = $order->sale_multi_times_rental( \@order_details );
            if ( $sale_price->{before} != $sale_price->{after} ) {
                my $sale = $schema->resultset('Sale')->find( { name => '3times' } );
                $order->create_related( 'order_sales', { sale_id => $sale->id } );
            }
        }

        for my $od (@order_details) {
            delete $od->{clothes_category};
            my $detail = $order->create_related( 'order_details', $od );
            die "Failed to create a new order_detail" unless $detail;
        }

        ## 일반적으로 `포장 -> 포장완료`는 offline 에서의 절차이므로 배송비(0)와 에누리(0)를 추가
        for my $name (qw/배송비 에누리/) {
            $order->create_related(
                'order_details',
                {
                    name        => $name,
                    price       => 0,
                    final_price => 0,
                }
            ) or die "Failed to create a new order_detail for $name";
        }

        $guard->commit;
        return 1;
    }
    catch {
        my $err = $_;
        return ( undef, $err );
    };

    unless ($success) {
        my $order_id = $order->id;
        warn "Failed to execute box2boxed($order_id): $error";
        return;
    }

    return 1 unless $self->{notify};

    $self->notify( $order, $BOX, $BOXED );
    return 1;
}

=head2 boxed2payment( $order )

    my $success = $api->boxed2payment($order);

=over

=item *

주문서의 상태를 C<$PAYMENT> 로 변경

=item *

opencloset/monitor 에 event 전달

=back

=cut

sub boxed2payment {
    my ( $self, $order ) = @_;
    return unless $order;

    $order->update( { status_id => $PAYMENT } );

    return 1 unless $self->{notify};

    $self->notify( $order, $BOXED, $PAYMENT );
    return 1;
}

=head2 payment2rental( $order, $pay_with, $additional_days? )

    my $success = $api->payment2rental($order, '현금', 4);

=head3 Args

=over

=item *

C<$order> - L<OpenCloset::Schema::Result::Order> obj

=item *

C<$pay_with> - 결제방법

=item *

연장일수 C<$additional_days> - default is C<0>

=back

=head3 Desc

=over

=item *

대여기간에 따라 반납희망일(C<user_target_date>)과 연장일(C<additional_day>)을 변경

=item *

대여일(C<rental_date>)을 현재시간으로 지정

=item *

결제방법(C<price_pay_with>)을 저장

=item *

주문서의 상태를 C<$RENTAL> 로 변경

=item *

쿠폰의 상태를 변경

=item *

의류(clothes)의 상태를 C<$RENTAL> 로 변경

=item *

주문내역 의류(order_detail)의 상태를 C<$RENTAL> 로 변경

=item *

대여자에게 주문내용 및 반납안내 SMS 전송

=item *

대여자에게 기증이야기 SMS 전송

=item *

monitor 에 이벤트 알림

=back

=cut

our $DEFAULT_RENTAL_DAYS = 3; # 3박4일

sub payment2rental {
    my ( $self, $order, $pay_with, $additional_days ) = @_;
    return unless $order;

    unless ($pay_with) {
        warn "pay_with is required";
        return;
    }

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;

    my ( $success, $error ) = try {
        my $tz          = $order->create_date->time_zone;
        my $rental_date = DateTime->today( time_zone => $tz->name );
        my %update      = (
            status_id      => $RENTAL,
            price_pay_with => $pay_with,
            rental_date    => $rental_date->datetime,
        );

        if ( $additional_days and $additional_days > 0 ) {
            $update{additional_day} = $additional_days;
            my $user_target_date = $rental_date->clone->truncate( to => 'day' );
            $user_target_date->add( days => $DEFAULT_RENTAL_DAYS + $additional_days );
            $user_target_date->set( hour => 23, minute => 59, second => 59 );
            $update{user_target_date} = $user_target_date->datetime;
        }

        ## update order status_id rental_date, additional_day and user_target_date
        $order->update( \%update );

        ## update clohtes.status_id to $RENTAL
        $order->clothes->update_all( { status_id => $RENTAL } );

        ## update order_details.status_id to $RENTAL
        $order->order_details( { clothes_code => { '!=' => undef } } )->update_all( { status_id => $RENTAL } );

        if ( my $coupon = $order->coupon ) {
            if ( $pay_with =~ m/쿠폰/ ) {
                $coupon->update( { status => 'used' } );
            }
        }

        $guard->commit;
        return 1;
    }
    catch {
        my $err = $_;
        return ( undef, $err );
    };

    unless ($success) {
        my $order_id = $order->id;
        warn "Failed to execute payment2rental($order_id): $error";
        return;
    }

    $self->notify( $order, $PAYMENT, $RENTAL ) if $self->{notify};

    return 1 unless $self->{sms};

    my $user      = $order->user;
    my $user_info = $user->user_info;
    my $sms       = OpenCloset::API::SMS->new( schema => $schema );

    my $mt  = Mojo::Template->new;
    my $tpl = data_section __PACKAGE__, 'order-confirm-1.txt';
    my $msg = $mt->render( $tpl, $order, $user );
    chomp $msg;

    $sms->send( to => $user_info->phone, msg => $msg );

    ## GH #949 - 기증 이야기 안내를 별도의 문자로 전송
    my @clothes;
    for my $clothes ( $order->clothes ) {
        my $donation = $clothes->donation;
        next unless $donation;
        next unless $donation->message;

        push @clothes, $clothes;
    }

    if (@clothes) {
        my %SCORE = (
            $JACKET    => 10,
            $PANTS     => 20,
            $SKIRT     => 30,
            $ONEPIECE  => 40,
            $COAT      => 50,
            $WAISTCOAT => 60,
            $SHIRT     => 70,
            $BLOUSE    => 80,
            $TIE       => 90,
            $BELT      => 100,
            $SHOES     => 110,
            $MISC      => 120,
        );

        my @sorted_clothes = sort { $SCORE{ $a->category } <=> $SCORE{ $b->category } } @clothes;
        my $first          = $sorted_clothes[0];
        my $donation       = $first->donation;
        my $category       = $OpenCloset::Constants::Category::LABEL_MAP{ $first->category };

        $tpl = data_section __PACKAGE__, 'order-confirm-2.txt';
        $msg = $mt->render( $tpl, $order, $user, $donation, $category );
        chomp $msg;

        $sms->send( to => $user_info->phone, msg => $msg );
    }

    return 1;
}

=head2 rental2returned( $order, %extra )

    my $success = $api->rental2returned($order, return_date => $return_date);

=head3 Arguments

=over

=item *

C<$order> - L<OpenCloset::Schema::Result::Order> obj

=item *

C<%extra> - 조건에 따라 필수 값이 달라집니다.

=over

=item *

C<return_date> - L<DateTime> obj
default 는 C<now()> 입니다.

=item *

C<late_fee_pay_with> - 연체/연장료 납부 방법

=item *

C<late_fee_discount> - 연체/연장료 에누리

=item *

C<compensation_price> - 배상비

=item *

C<compensation_discount> - 배상비 에누리

=back

=back

=head3 Desc

=over

=item *

반납일을 변경

=item *

연체/연장료 납부방법을 저장(C<late_fee_pay_with>)

=item *

배상료 납부방법을 저장(C<compensation_pay_with>)

=item *

연체료 항목을 추가(stage: 1)

    연체료: 30,000 x 30% x 2일

=item *

연장료 항목을 추가(stage: 1)

    연장료: 30,000 x 20% x 2일

=item *

연체/연장료 에누리 항목 추가(stage: 1)

    연체/연장료 에누리

=item *

배상비 항목을 추가(stage: 2)

=item *

배상비 에누리 항목을 추가(stage: 2)

=item *

주문서의 상태를 C<$RETURNED> 로 변경

=item *

주문내역 및 주문내역의 의류의 상태를 C<$RETURNED> 로 변경

=item *

대여자에게 반납문자 전송

=item *

monitor 에 이벤트 알림

=back

=cut

sub rental2returned {
    my ( $self, $order, %extra ) = @_;
    return unless $order;

    my $return_date = $extra{return_date};
    unless ($return_date) {
        my $tz = $order->create_date->time_zone;
        $return_date = DateTime->now( time_zone => $tz );
    }

    my $is_late;
    my $late_fee_pay_with     = $extra{late_fee_pay_with};
    my $late_fee_discount     = $extra{late_fee_discount};
    my $compensation_pay_with = $extra{compensation_pay_with};
    my $compensation_price    = $extra{compensation_price};
    my $compensation_discount = $extra{compensation_discount};

    if ($compensation_price) {
        die "'compensation_pay_with' is required" unless $compensation_pay_with;
    }

    my $calc           = OpenCloset::Calculator::LateFee->new;
    my $extension_days = $calc->extension_days( $order, $return_date->datetime );
    my $overdue_days   = $calc->overdue_days( $order, $return_date->datetime );

    if ( $extension_days or $overdue_days ) {
        $is_late = 1;
        die "'late_fee_pay_with' is required" unless $late_fee_pay_with;
    }

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;

    my ( $success, $error ) = try {
        if ( my $extension_days = $calc->extension_days( $order, $return_date->datetime ) ) {
            my $price = $calc->rental_price($order);
            my $rate  = $OpenCloset::Calculator::LateFee::EXTENSION_RATE;

            $order->create_related(
                'order_details',
                {
                    name        => '연장료',
                    price       => $price * $rate,
                    final_price => $price * $rate * $extension_days,
                    stage       => 1,
                    desc        => sprintf( '%s원 x %d%% x %d일', $self->commify($price), $rate * 100, $extension_days ),
                    pay_with    => $late_fee_pay_with,
                }
            ) or die "Failed to create a new order_detail for 연장료";
        }

        if ( my $overdue_days = $calc->overdue_days( $order, $return_date->datetime ) ) {
            my $price = $calc->rental_price($order);
            my $rate  = $OpenCloset::Calculator::LateFee::OVERDUE_RATE;

            $order->create_related(
                'order_details',
                {
                    name        => '연체료',
                    price       => $price * $rate,
                    final_price => $price * $rate * $overdue_days,
                    stage       => 1,
                    desc        => sprintf( '%s원 x %d%% x %d일', $self->commify($price), $rate * 100, $overdue_days ),
                    pay_with    => $late_fee_pay_with,
                }
            ) or die "Failed to create a new order_detail for 연체료";
        }

        if ( $is_late and $late_fee_discount ) {
            $late_fee_discount *= -1 if $late_fee_discount > 0;
            $order->create_related(
                'order_details',
                {
                    name        => '연체/연장료 에누리',
                    price       => $late_fee_discount,
                    final_price => $late_fee_discount,
                    stage       => 1,
                }
            ) or die "Failed to create a new order_detail for 연체/연장료 에누리";
        }

        if ($compensation_price) {
            $order->create_related(
                'order_details',
                {
                    name        => '배상비',
                    price       => $compensation_price,
                    final_price => $compensation_price,
                    stage       => 2,
                    pay_with    => $compensation_pay_with,
                }
            ) or die "Failed to create a new order_detail for 배상비";

            if ($compensation_discount) {
                $compensation_discount *= -1 if $compensation_discount > 0;
                $order->create_related(
                    'order_details',
                    {
                        name        => '배상비 에누리',
                        price       => $compensation_discount,
                        final_price => $compensation_discount,
                        stage       => 2,
                    }
                ) or die "Failed to create a new order_detail for 배상비 에누리";
            }
        }

        $order->update(
            {
                status_id             => $RETURNED,
                return_date           => $return_date->datetime,
                late_fee_pay_with     => $late_fee_pay_with,
                compensation_pay_with => $compensation_pay_with,
            }
        );
        $order->clothes->update_all( { status_id => $RETURNED } );
        $order->order_details( { clothes_code => { '!=' => undef } } )->update_all( { status_id => $RETURNED } );

        $guard->commit;
        return 1;
    }
    catch {
        my $err = $_;
        return ( undef, $err );
    };

    unless ($success) {
        my $order_id = $order->id;
        warn "Failed to execute rental2returned($order_id): $error";
        return;
    }

    $self->notify( $order, $RENTAL, $RETURNED ) if $self->{notify};
    return 1 unless $self->{sms};

    ## TODO
    ## "[열린옷장] #{username}님의 의류가 정상적으로 반납되었습니다. 감사합니다." sms

    return 1;
}

=head2 additional_day( $order, $days )

    my $success = $api->additional_day($order, 2);    # 2일 연장

반납희망일(C<order.user_target_date>)과 최종금액(C<order_detail.final_price>)을 변경합니다.

=over

=item *

C<$order> - L<OpenCloset::Schema::Result::Order> obj

=item *

$days - 연장일

=back

=cut

sub additional_day {
    my ( $self, $order, $days ) = @_;
    return unless $order;
    return unless $days;

    if ( $order->status_id != $PAYMENT ) {
        warn "status_id should be 'PAYMENT'";
        return;
    }

    if ( $days < 0 ) {
        warn "additional_day should be over than 0";
        return;
    }

    my $user_target_date = $order->user_target_date;
    $user_target_date->add( days => $days );

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;
    my ( $success, $error ) = try {
        $order->update(
            {
                additional_day   => $days,
                user_target_date => $user_target_date->datetime,
            }
        );

        my $details = $order->order_details( { stage => 0, clothes_code => { '!=' => undef } } );
        while ( my $detail = $details->next ) {
            my $price       = $detail->price;
            my $final_price = $price + $price * $OpenCloset::Calculator::LateFee::EXTENSION_RATE * $days;
            $detail->update( { final_price => $final_price } );
        }

        $guard->commit;
        return 1;
    }
    catch {
        my $err = $_;
        return ( undef, $err );
    };

    unless ($success) {
        my $order_id = $order->id;
        warn "Failed to execute additional_day($order_id): $error";
        return;
    }

    return 1;
}

=head2 notify( $order, $status_from, $status_to )

    my $res = $self->notify($order, $BOXED, $PAYMENT);

=cut

sub notify {
    my ( $self, $order, $from, $to ) = @_;
    return unless $order;
    return unless $from;
    return unless $to;

    my $res = $self->{http}->post_form(
        "$MONITOR_HOST/events",
        { sender => 'order', order_id => $order->id, from => $from, to => $to }
    );

    warn "Failed to post event to monitor: $MONITOR_HOST/events: $res->{reason}" unless $res->{success};
    return $res;
}

=head2 commify

    $self->commify(10000);    # 10,000

=cut

sub commify {
    my $self = shift;
    local $_ = shift;
    1 while s/((?:\A|[^.0-9])[-+]?\d+)(\d{3})/$1,$2/s;
    return $_;
}

=head1 AUTHOR

Hyungsuk Hong

=head1 COPYRIGHT

The MIT License (MIT)

Copyright (c) 2017 열린옷장

=cut

1;

__DATA__

@@ order-confirm-1.txt
% my ($order, $user) = @_;
[열린옷장] <%= $user->name %>님 안녕하세요. 택배반납을 하시거나 연장신청이 필요한 경우, 본 문자를 보관하고 계시다가 반드시 아래 주소를 클릭하여 정보를 입력해주세요. 정보 미입력시 미반납, 연체 상황이 발생할 수 있으므로 반드시 본 정보 작성을 요청드립니다. 감사합니다.

1. 택배로 발송을 하신 경우: https://staff.theopencloset.net/order/<%= $order->id %>/return/ 를 클릭하여 반납택배 발송알리미를 작성해주세요.

서울시 광진구 아차산로 213(화양동 48-3번지) 웅진빌딩 403호 열린옷장

2. 대여기간을 연장 하려는 경우: https://staff.theopencloset.net/order/<%= $order->id %>/extension/ 를 클릭하여 대여기간 연장신청서를 작성해주세요.

@@ order-confirm-2.txt
% my ($order, $user, $donation, $category) = @_;
% my $donator = $donation->user;
[열린옷장] 안녕하세요. <%= $user->name %>님.
<%= $category %> 기증자 <%= $donator->name %>님의 기증 편지를 읽어보세요.

----

<%= $donation->message %>

----

<%= $user->name %>님이 대여하신 다른 의류의 기증자 이야기를 읽으시려면 URL을 클릭해 주세요.

https://story.theopencloset.net/letters/o/<%= $order->id %>/d
