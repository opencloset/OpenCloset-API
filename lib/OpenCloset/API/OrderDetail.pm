package OpenCloset::API::OrderDetail;

use utf8;
use strict;
use warnings;

use OpenCloset::Calculator::LateFee ();

=encoding utf8

=head1 NAME

OpenCloset::API::OrderDetail - 주문서 상세항목의 API

=head1 SYNOPSIS

    my $api = OpenCloset::API::OrderDetail->new(schema => $schema);
    $api->update_price($detail, 3000);

=head1 METHODS

=head2 new

    my $api = OpenCloset::API::OrderDetail->new(schema => $schema);

=over

=item *

schema - S<OpenCloset::Schema>

=back

=cut

sub new {
    my ( $class, %args ) = @_;
    return unless $args{schema};

    my $self = { schema => $args{schema} };

    bless $self, $class;
    return $self;
}

=head2 update_price( $detail, $price )

    ## 자켓의 가격을 5000 원으로 변경
    ## 대여일수에 따라 final_price 가 변경됨
    $api->update_price($detail, 5_000)

=cut

sub update_price {
    my ( $self, $detail, $price ) = @_;
    return unless $detail;
    return unless defined $price;

    my $final_price = $price;
    if ( defined $detail->clothes_code and $detail->stage == 0 ) {
        my $order          = $detail->order;
        my $additional_day = $order->additional_day;
        $final_price = $price + $price * $OpenCloset::Calculator::LateFee::EXTENSION_RATE * $additional_day;
    }

    $detail->update(
        {
            price       => $price,
            final_price => $final_price,
        }
    );

    return $detail;
}

=head1 AUTHOR

Hyungsuk Hong

=head1 COPYRIGHT

The MIT License (MIT)

Copyright (c) 2017 열린옷장

=cut

1;
