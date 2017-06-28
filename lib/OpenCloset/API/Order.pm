package OpenCloset::API::Order;

use utf8;
use strict;
use warnings;

use HTTP::Tiny;
use Try::Tiny;

use OpenCloset::Constants::Category ();
use OpenCloset::Constants::Status qw/$BOX $BOXED $PAYMENT/;

=encoding utf8

=head1 NAME

OpenCloset::API::Order

=head1 SYNOPSIS

=cut

our $MONITOR_HOST = $ENV{OPENCLOSET_MONITOR_HOST} || "https://monitor.theopencloset.net";

=head1 METHODS

=head2 new

    my $api = OpenCloset::API::Order->new(schema => $schema);

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = {
        schema => $args{schema},
        http   => HTTP::Tiny->new(
            timeout         => 1,
            default_headers => {
                agent        => __PACKAGE__,
                content_type => 'application/json',
            }
        ),
    };

    bless $self, $class;
    return $self;
}

=head2 box2boxed( \@clothes_code )

포장 -> 포장완료

    my $success = $api->box2boxed(['J001', 'P001']);

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

opencloset/monitor 에 event 를 posting

=back

=cut

sub box2boxed {
    my ( $self, $order, $codes ) = @_;

    return unless @$codes;
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

            ## 3회 이상 대여 할인에 사용된 후에
            push @order_details, {
                clothes_code => $code,
                status_id    => $PAYMENT,
                name         => $name,
                price        => $clothes->price,
                final_price  => $clothes->price,
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

        my $sale_price = {
            before                => 0,
            after                 => 0,
            rented_without_coupon => 0,
        };

        ## 쿠폰이 사용된 주문서는 3회 이상 할인에서 제외한다.
        my $coupon = $order->coupon;
        if ( !$coupon ) {
            $sale_price = $order->sale_multi_times_rental( \@order_details );
            $self->log->debug(
                sprintf(
                    "order %d: %d rented without coupon",
                    $order->id,
                    $sale_price->{rented_without_coupon},
                )
            );
        }
    }
    catch {
        my $err      = $_;
        my $order_id = $order->id;
        warn "Failed to update box2boxed($order_id)";
        return ( undef, $err );
    };

    if ($success) {
        my $res = $self->{http}->post_form(
            "$MONITOR_HOST/events",
            { sender => 'order', order_id => $order->id, from => $BOX, to => $BOXED }
        );

        warn "Failed to post event to monitor: $MONITOR_HOST/events: $res->{reason}" unless $res->{success};
    }

    # opencloset/monitor 에 event posting
    # order_details 를 결제대기로 변경
    # $shoes.length 를 user_info.foot 에 반영
    # 3회 이상 비용할인
    # 배송비
    # 에누리
    # 쿠폰을 고려
}

1;
