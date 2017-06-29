package OpenCloset::API::Order;

use utf8;
use strict;
use warnings;

use HTTP::Tiny;
use Try::Tiny;

use OpenCloset::Constants::Category ();
use OpenCloset::Constants::Status qw/$BOX $BOXED $PAYMENT $CHOOSE_CLOTHES $CHOOSE_ADDRESS $PAYMENT $PAYMENT_DONE $WAITING_DEPOSIT $PAYBACK/;

use OpenCloset::DB::Plugin::Order::Sale;

=encoding utf8

=head1 NAME

OpenCloset::API::Order - 주문서의 상태변경 API

=head1 SYNOPSIS

    my $api = OpenCloset::API::Order(schema => $schema);
    my $success = $api->box2boxed($order, ['J001', 'P001']);    # 포장 -> 포장완료

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

=back

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = {
        schema => $args{schema},
        notify => $args{notify} // 1,
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

    my $res = $self->{http}->post_form(
        "$MONITOR_HOST/events",
        { sender => 'order', order_id => $order->id, from => $BOX, to => $BOXED }
    );

    warn "Failed to post event to monitor: $MONITOR_HOST/events: $res->{reason}" unless $res->{success};

    return 1;
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
