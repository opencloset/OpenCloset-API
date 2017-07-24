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
use OpenCloset::Constants::Status qw/$RENTAL $BOX $BOXED $PAYMENT $RETURNED $CANCEL_BOX $PAYBACK/;

use OpenCloset::DB::Plugin::Order::Sale;

=encoding utf8

=head1 NAME

OpenCloset::API::Order - 주문서의 상태변경 API

=head1 SYNOPSIS

    my $api = OpenCloset::API::Order->new(schema => $schema);
    $api->box2boxed($order, ['J001', 'P001']);               # 포장 -> 포장완료
    $api->boxed2payment($order);                             # 포장완료 -> 결제대기
    $api->payment2rental($order, '현금');                     # 결제대기 -> 대여중
    $api->rental2returned($order);                           # 대여중 -> 반납
    $api->rental2partial_returned($order, ['J001', 'P001']); # 대여중 -> 부분반납

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
    @codes = $self->_sort_codes(@codes);

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

C<target_date> 와 C<user_target_date> 를 3박 4일로 설정

=item *

opencloset/monitor 에 event 전달

=back

=cut

sub boxed2payment {
    my ( $self, $order ) = @_;
    return unless $order;

    my $tz               = $order->create_date->time_zone;
    my $today            = DateTime->today( time_zone => $tz->name );
    my $target_date      = $today->clone->add( days => 3 )->set( hour => 23, minute => 59, second => 59 );
    my $user_target_date = $target_date->clone;
    $order->update(
        {
            status_id        => $PAYMENT,
            target_date      => $target_date->datetime,
            user_target_date => $user_target_date->datetime
        }
    );

    return 1 unless $self->{notify};

    $self->notify( $order, $BOXED, $PAYMENT );
    return 1;
}

=head2 payment2rental( $order, %extra )

    my $success = $api->payment2rental($order, price_pay_with => '현금', additional_day => 4);

=head3 Args

=over

=item *

C<$order> - L<OpenCloset::Schema::Result::Order> obj

=item *

C<price_pay_with> - 결제방법

=item *

C<additional_day> - 연장일수 default is C<0>

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

쿠폰이 있다면 쿠폰의 상태를 C<used> 로 변경

=item *

사용자의 신체치수를 복사

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
    my ( $self, $order, %extra ) = @_;
    return unless $order;

    my $price_pay_with = $extra{price_pay_with} ||= $order->price_pay_with;
    unless ($price_pay_with) {
        warn "price_pay_with is required";
        return;
    }

    $self->additional_day( $order, $extra{additional_day} ) if defined $extra{additional_day};

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;

    my $user      = $order->user;
    my $user_info = $user->user_info;

    my ( $success, $error ) = try {
        my $tz = $order->create_date->time_zone;
        my $rental_date = DateTime->today( time_zone => $tz->name ); # 왜 now 가 아니라 today 인거지?

        ## 사용자의 신체치수를 복사
        my %size;
        map { $size{$_} = $user_info->$_ } qw/height weight neck bust waist hip topbelly belly thigh arm leg knee foot pants skirt/;

        $order->update(
            {
                status_id      => $RENTAL,
                price_pay_with => $price_pay_with,
                rental_date    => $rental_date->datetime,
                %size,
            }
        );
        $order->clothes->update_all( { status_id => $RENTAL } );
        $order->order_details( { clothes_code => { '!=' => undef } } )->update_all( { status_id => $RENTAL } );

        if ( my $coupon = $order->coupon ) {
            if ( $price_pay_with =~ m/쿠폰/ ) {
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

    my $sms = OpenCloset::API::SMS->new( schema => $schema );
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
    my $late_fee_pay_with     = $extra{late_fee_pay_with}     || $order->late_fee_pay_with;
    my $compensation_pay_with = $extra{compensation_pay_with} || $order->compensation_pay_with;

    my $late_fee_discount     = $extra{late_fee_discount};
    my $compensation_price    = $extra{compensation_price};
    my $compensation_discount = $extra{compensation_discount};

    if ( $compensation_price and !$compensation_pay_with ) {
        warn "'compensation_pay_with' is required";
        return;
    }

    my $calc           = OpenCloset::Calculator::LateFee->new;
    my $extension_days = $calc->extension_days( $order, $return_date->datetime );
    my $overdue_days   = $calc->overdue_days( $order, $return_date->datetime );

    if ( $extension_days or $overdue_days ) {
        $is_late = 1;

        unless ($late_fee_pay_with) {
            warn "'late_fee_pay_with' is required";
            return;
        }
    }

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;

    my ( $success, $error ) = try {
        my $price    = $calc->price($order);
        my $discount = $calc->discount_price($order);
        my $coupon   = $order->coupon;
        if ( $coupon and $coupon->type eq 'suit' ) {
            ## suit type 쿠폰일때는 정상금액을 기준으로 계산
        }
        else {
            ## 이외에는 대여금액으로 계산: 대여금액 = 정상금액 - 할인금액
            $price += $discount;
        }

        if ( my $extension_days = $calc->extension_days( $order, $return_date->datetime ) ) {
            my $rate = $OpenCloset::Calculator::LateFee::EXTENSION_RATE;

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
            my $rate = $OpenCloset::Calculator::LateFee::OVERDUE_RATE;

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

    my $user      = $order->user;
    my $user_info = $user->user_info;
    my $sms       = OpenCloset::API::SMS->new( schema => $schema );
    my $mt        = Mojo::Template->new;
    my $tpl       = data_section __PACKAGE__, 'returned-1.txt';
    my $msg       = $mt->render( $tpl, $order, $user );
    chomp $msg;

    $sms->send( to => $user_info->phone, msg => $msg );

    return 1;
}

=head2 rental2partial_returned( $order, \@codes )

    my $success = $api->rental2partial_returned($order, ['J001', 'P001']);

=over

=item *

현재 주문서의 내용을 복사해서 새로운 주문서를 만듦
이때에 반납되지 않은 의류들만 포함

=item *

정상적인 절차를 통해서 새로 만든 주문서의 상태를

    $BOX -> $BOXED -> $PAYMENT

로 변경

=item *

새로 만든 주문서 C<order_detail> 의 C<price>, C<final_price>, C<desc> 를 reset

=item *

현재 주문서에 대해 C<rental2returned>(대여중 -> 반납) 를 호출해서 반납으로 변경

=item *

opencloset/monitor 에 event 를 posting

=back

=cut

sub rental2partial_returned {
    my ( $self, $order, $codes, %extra ) = @_;
    return unless $order;
    return unless @{ $codes ||= [] };

    my %seen;
    my @codes = map { sprintf( '%05s', $_ ) } @$codes;
    my $clothes = $order->clothes;

    while ( my $c = $clothes->next ) {
        $seen{ $c->code }++;
    }

    map { delete $seen{$_} } @codes;
    @codes = keys %seen;
    unless (@codes) {
        warn "All clothes are returned";
        return;
    }

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;
    my $notify = delete $self->{notify};
    my $sms    = delete $self->{sms};

    my ( $success, $error ) = try {
        my %columns = $order->get_columns;

        my $parent_id = delete $columns{id};
        map { delete $columns{$_} } qw/additional_day return_date return_method late_fee_pay_with price_pay_with/;

        $columns{status_id} = $BOX;
        $columns{coupon_id} = undef;
        $columns{parent_id} = $parent_id;

        my $child = $schema->resultset('Order')->create( \%columns );
        die "Failed to create a new order" unless $child;

        $self->box2boxed( $child, \@codes );
        $self->boxed2payment($child);

        my $tz = $order->create_date->time_zone;
        my $now = DateTime->now( time_zone => $tz->name );
        $child->update( { target_date => $now->datetime, user_target_date => $now->datetime } );

        my $details = $child->order_details( { stage => 0, clothes_code => { '!=' => undef } } );
        $details->update_all( { price => 0, final_price => 0, desc => undef } );
        $self->rental2returned( $order, %extra );
        $guard->commit;
        return 1;
    }
    catch {
        my $err = $_;
        return ( undef, $err );
    }
    finally {
        $self->{notify} = $notify;
        $self->{sms}    = $sms;
    };

    unless ($success) {
        my $order_id = $order->id;
        warn "Failed to execute rental2partial_returned($order_id): $error";
        return;
    }

    $self->notify( $order, $RENTAL, $RETURNED ) if $self->{notify};
    return 1;
}

=head2 payment2box

    my $success = $api->payment2box($order);    # 새로주문

새로주문

=over

=item *

포장된 의류의 상태를 C<$CANCEL_BOX> 로 변경

=item *

상세항목을 모두 제거

=item *

상태를 C<$BOX> 로 변경

=item *

결제 및 반납과 관련된 컬럼을 reset

=over

=item *

staff_id

=item *

rental_date

=item *

target_date

=item *

user_target_date

=item *

return_date

=item *

return_method

=item *

price_pay_with

=item *

late_fee_pay_with

=item *

bestfit

=back

=back

=cut

sub payment2box {
    my ( $self, $order ) = @_;
    return unless $order;

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;

    my ( $success, $error ) = try {
        $order->clothes->update_all( { status_id => $CANCEL_BOX } );
        $order->order_details->delete_all;
        $order->update(
            {
                status_id         => $BOX,
                staff_id          => undef,
                rental_date       => undef,
                target_date       => undef,
                user_target_date  => undef,
                return_date       => undef,
                return_method     => undef,
                price_pay_with    => undef,
                late_fee_pay_with => undef,
                bestfit           => 0,
            }
        );

        $guard->commit;
        return 1;
    }
    catch {
        my $err = $_;
        return ( undef, $err );
    };

    unless ($success) {
        my $order_id = $order->id;
        warn "Failed to execute payment2box($order_id): $error";
        return;
    }

    return 1 unless $self->{notify};

    $self->notify( $order, $PAYMENT, $BOX );
    return 1;
}

=head2 rental2payback( $order, $charge? )

    my $success = $api->rental2payback($order, 5_000)

환불

=over

=item *

C<order_detail> 항목을 추가

    name:        환불
    price:       대여비 * -1
    final_price: 대여비 * -1
    stage:       3
    desc:        환불 수수료: $charge원

=item *

주문서 의류의 상태를 C<$PAYBACK> 으로 변경

=item *

주문서의 상태를 C<$PAYBACK> 으로 변경

=back

=cut

sub rental2payback {
    my ( $self, $order, $charge ) = @_;
    return unless $order;

    $charge ||= 0;

    my $calc         = OpenCloset::Calculator::LateFee->new;
    my $rental_price = $calc->rental_price($order);

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;

    my ( $success, $error ) = try {
        $order->create_related(
            'order_details',
            {
                name        => '환불',
                price       => ( $rental_price - $charge ) * -1,
                final_price => ( $rental_price - $charge ) * -1,
                stage       => 3,
                desc        => sprintf( '환불 수수료: %s원', $self->commify($charge) ),
            }
        ) or die "Failed to create a new order_detail for 환불";

        $order->clothes->update_all( { status_id => $PAYBACK } );
        $order->update( { status_id => $PAYBACK } );

        ## 환불하면 쿠폰을 사용가능하도록 변경한다
        ## https://github.com/opencloset/opencloset/issues/1193
        if ( my $coupon = $order->coupon ) {
            $coupon->update( { status => 'reserved' } );
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
        warn "Failed to execute rental2payback($order_id): $error";
        return;
    }

    return 1 unless $self->{notify};

    $self->notify( $order, $RENTAL, $PAYBACK );
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
    return unless defined $days;

    if ( $order->status_id != $PAYMENT ) {
        warn "status_id should be 'PAYMENT'";
        return;
    }

    if ( $days < 0 ) {
        warn "additional_day should be over than 0";
        return;
    }

    ## 오늘날짜를 기준으로 바뀌어야 한다
    ## 반납예정일 반납희망일 모두
    my $tz               = $order->create_date->time_zone;
    my $today            = DateTime->today( time_zone => $tz->name );
    my $target_date      = $today->clone->add( days => 3 + $days )->set( hour => 23, minute => 59, second => 59 );
    my $user_target_date = $target_date->clone;

    my $schema = $self->{schema};
    my $guard  = $schema->txn_scope_guard;
    my ( $success, $error ) = try {
        $order->update(
            {
                additional_day   => $days,
                target_date      => $target_date->datetime,
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

=head2 _sort_codes( @codes )

sort clothes codes by score.

    my @codes = qw/0S003 0J001 0P001 0A001/;
    @codes = $self->_sort_codes(@codes);    # ("0J001", "0P001", "0S003", "0A001")

=cut

sub _sort_codes {
    my ( $self, @codes ) = @_;

    my %SCORE = (
        J => 10,  # JACKET
        P => 20,  # PANTS
        K => 30,  # SKIRT
        O => 40,  # ONEPIECE
        C => 50,  # COAT
        W => 60,  # WAISTCOAT
        S => 70,  # SHIRT
        B => 80,  # BLOUSE
        T => 90,  # TIE
        E => 100, # BELT
        A => 110, # SHOES
        M => 120, # MISC
    );

    return sort {
        my $i = $a =~ m/^0/ ? 1 : 0;
        my $j = $b =~ m/^0/ ? 1 : 0;
        $SCORE{ substr( $a, $i, 1 ) } <=> $SCORE{ substr( $b, $j, 1 ) }
    } @codes;
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

@@ returned-1.txt
% my ($order, $user) = @_;
[열린옷장] <%= $user->name %>님의 의류가 정상적으로 반납되었습니다. 감사합니다.
