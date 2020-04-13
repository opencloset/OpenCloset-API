package OpenCloset::API::Order;

use utf8;
use strict;
use warnings;

use DateTime;
use DateTime::Format::ISO8601;
use HTTP::Tiny;
use Mojo::Loader qw/data_section/;
use Mojo::Template;
use Try::Tiny;

use OpenCloset::API::SMS;
use OpenCloset::Calculator::LateFee;
use OpenCloset::Constants::Category;
use OpenCloset::Constants::Status qw/$RENTAL $RESERVATED $BOX $BOXED $PAYMENT $RETURNED $CANCEL_BOX $PAYBACK/;
use OpenCloset::Events::EmploymentWing ();

use OpenCloset::DB::Plugin::Order::Sale;

our $SEOUL_EVENT_MIN_AGE = 18;
our $SEOUL_EVENT_MAX_AGE = 35;

=encoding utf8

=head1 NAME

OpenCloset::API::Order - 주문서의 상태변경 API

=head1 SYNOPSIS

    my $api = OpenCloset::API::Order->new(
        schema      => $schema,
        monitor_uri => 'https://monitor.theopencloset.net',
    );
    $api->reservated($user, '2017-09-19T16:00:00');             # 방문예약
    $api->update_reservated($order, $datetime);                 # 방문예약 변경
    $api->cancel($order);                                       # 방문예약 취소
    $api->box2boxed($order, ['J001', 'P001']);                  # 포장 -> 포장완료
    $api->boxed2payment($order);                                # 포장완료 -> 결제대기
    $api->payment2rental($order, price_pay_with => '현금');      # 결제대기 -> 대여중
    $api->rental2returned($order);                              # 대여중 -> 반납
    $api->rental2partial_returned($order, ['J001', 'P001']);    # 대여중 -> 부분반납

=cut

=head1 METHODS

=head2 new

    my $api = OpenCloset::API::Order->new(
        schema      => $schema,
        monitor_uri => 'https://monitor.theopencloset.net',
    );

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

=item *

monitor_uri - Str

모니터 서비스 URI 입니다.
default 는 C<""> 입니다.

=back

=cut

sub new {
    my ( $class, %args ) = @_;

    my $self = {
        schema      => $args{schema},
        notify      => $args{notify} // 1,
        sms         => $args{sms} // 1,
        monitor_uri => $args{monitor_uri} // q{},
        http        => HTTP::Tiny->new(
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

=head2 reservated( $user, $datetime, %extra )

B<주문서없음> -> B<방문예약>

    my $order = $api->reservated($user, '2017-09-19T16:00:00');

L<https://github.com/opencloset/opencloset/issues/1627>

예약확정이 되었을때에 더 이상의 slot 이 없다면,
동시간대의 다른 성별의 에약 버퍼 slot 을 하나 가져옵니다.
가능한 최대의 예약을 소화하기 위함 입니다.

=head3 C<%extra> Args

=over

=item *

C<booking>

L<DateTime> object or C<YYYY-MM-DDThh:mm:ss> formatted string.

=item *

C<coupon>

=item *

C<agent> - boolean

대리인 대여 여부

=item *

C<ignore> - boolean

검색결과에 포함되지 않습니다.

=item *

C<online> - boolean

온라인 주문서 여부

=item *

C<past_order>

지난 대여이력중에 재대여를 원하는 주문서 번호

=item *

C<skip_jobwing> - boolean

true 일때에 취업날개 서비스의 예약시간을 변경하지 않습니다.

=back

=cut

sub reservated {
    my ( $self, $user, $datetime, %extra ) = @_;
    return unless $user;
    return unless $datetime;

    my $user_info = $user->user_info;
    return unless $user_info;

    if ( ref($datetime) ne 'DateTime' ) {
        my $tz = $user->create_date->time_zone;
        $datetime = DateTime::Format::ISO8601->parse_datetime($datetime);
        $datetime->set_time_zone($tz);
    }

    my $schema  = $self->{schema};
    my $booking = $schema->resultset('Booking')->find(
        {
            date   => "$datetime",
            gender => $user_info->gender,
        }
    );

    unless ($booking) {
        warn "Booking datetime is not avaliable: $datetime";
        return;
    }

    my %args = (
        user_id     => $user->id,
        status_id   => $RESERVATED,
        booking_id  => $booking->id,
        wearon_date => $user_info->wearon_date,
        coupon_id   => $extra{coupon} ? $extra{coupon}->id : undef,
        agent  => $extra{agent}  || 0,
        ignore => $extra{ignore} || 0,
        online => $extra{online} || 0,
    );

    if ( my $id = $extra{past_order} ) {
        my $order = $schema->resultset('Order')->find( { id => $id } );
        if ( $order and $order->rental_date ) {
            $args{misc} = sprintf( "%s 대여했던 의류를 다시 대여하고 싶습니다.", $order->rental_date->ymd );
        }
    }

    my $guard = $schema->txn_scope_guard;
    my ( $order, $error ) = try {
        ## coupon 중복사용 허용하지 않음
        $self->transfer_order( $extra{coupon} ) if $extra{coupon};

        my $order = $schema->resultset('Order')->create( \%args );
        die "Failed to create a new order" unless $order;

        $self->take_booking_slot_if_available($datetime, $user_info->gender);
        $self->_update_interview_type( $order, $extra{interview} );

        $guard->commit;
        return $order;
    }
    catch {
        my $err = $_;
        return ( undef, $err );
    };

    unless ($order) {
        warn "reservated failed: $error";
        return;
    }

    my $is_jobwing;
    if ( my $coupon = $order->coupon ) {
        my $desc = $coupon->desc || '';
        if ( $desc =~ m/^seoul/ ) {
            $is_jobwing = 1;
            unless ( $extra{skip_jobwing} ) {
                my ( $name, $rent_num, $mbersn ) = split /\|/, $desc;
                my $order_id = $order->id;
                my $client   = OpenCloset::Events::EmploymentWing->new;
                my $success  = $client->update_booking_datetime( $rent_num, $datetime );
                warn "Failed to update jobwing booking_datetime: rent_num($rent_num), order($order_id), datetime($datetime)"
                    unless $success;
            }
        }
    }

    return $order unless $self->{sms};

    my $sms      = OpenCloset::API::SMS->new( schema => $schema );
    my $mt       = Mojo::Template->new;
    my $tpl      = data_section __PACKAGE__, 'order-reserved-1.txt';
    my $order_id = $order->id;
    my $tail     = substr( $user_info->phone, -4 );
    my $msg      = $mt->render(
        $tpl,
        $order,
        $user->name,
        $datetime->strftime('%m월 %d일 %H시 %M분'),
        "https://visit.theopencloset.net/order/$order_id/booking/edit?phone=$tail"
    );
    chomp $msg;
    $sms->send( to => $user_info->phone, msg => $msg );

    ## https://github.com/opencloset/OpenCloset-API/issues/31
    ## 예약직후에 서울시 쿠폰 대상자에게 문자발송
    unless ($is_jobwing or $order->coupon) {
        my $birth   = $user_info->birth;
        my $tz      = $order->create_date->time_zone;
        my $today   = DateTime->today( time_zone => $tz->name );
        my $year    = $today->year;
        my $age     = $year - $birth;
        my $purpose = $user_info->purpose || '';
        my $addr    = $user_info->address2 || $user_info->address3 || '';
        if ($age >= $SEOUL_EVENT_MIN_AGE
                && $age <= $SEOUL_EVENT_MAX_AGE
                && ($purpose eq '입사면접' || $purpose eq '인턴면접')
                && $addr =~ m/^서울/) {

            ## 이벤트 기간이 아닐때에는 보내지 않는다.
            my $event = $schema->resultset('Event')->search({
                name => "seoul-$year-1",
            }, {
                order_by => {
                    -desc => 'create_date'
                }
            })->next;
            return $order unless $event;

            my $eventStartDate = $event->start_date;
            my $eventEndDate = $event->end_date;

            return $order if $today->epoch < $eventStartDate->epoch;
            return $order if $today->epoch > $eventEndDate->epoch;

            $tpl = data_section __PACKAGE__, 'employment-wing-target.txt';
            $msg = $mt->render($tpl);
            chomp $msg;
            $sms->send( to => $user_info->phone, msg => $msg );
        }
        return $order;
    }

    return $order unless $is_jobwing;

    my $year = (localtime)[5] + 1900;
    $tpl = data_section __PACKAGE__, 'employment-wing.txt';
    $msg = $mt->render($tpl, $year);
    chomp $msg;
    $sms->send( to => $user_info->phone, msg => $msg );

    return $order;
}

=head2 update_reservated($order, $datetime, %extra)

    my $success = $api->update_reservateda($order, '2017-09-20T10:00:00');

예약시간을 변경하고 변경안내 SMS 를 보냅니다.

=head3 Args

=over

=item *

C<$order>

=item *

C<$datetime> - L<DateTime> object or C<YYYY-MM-DDThh:mm:ss> formatted string.

=item *

C<%extra>

=over

=item *

C<coupon> - L<OpenCloset::Schema::Result::Coupon> object.

쿠폰없이 예약했던 주문서에 쿠폰을 넣을 수 있습니다.

=item *

C<agent> - boolean

대리인 대여 여부

=item *

C<ignore> - boolean

검색결과에 포함되지 않습니다.

=item *

C<online> - boolean

온라인 주문서 여부

=item *

C<skip_jobwing> - boolean

true 일때에 취업날개 서비스의 예약시간을 변경하지 않습니다.

=back

=back

=cut

sub update_reservated {
    my ( $self, $order, $datetime, %extra ) = @_;
    return unless $order;
    return unless $datetime;
    return if $order->status_id != $RESERVATED && $order->status_id != $PAYMENT;

    if ( ref($datetime) ne 'DateTime' ) {
        my $tz = $order->create_date->time_zone;
        $datetime = DateTime::Format::ISO8601->parse_datetime($datetime);
        $datetime->set_time_zone($tz);
    }

    my $schema    = $self->{schema};
    my $user      = $order->user;
    my $user_info = $user->user_info;
    my $booking   = $schema->resultset('Booking')->find(
        {
            date   => "$datetime",
            gender => $user_info->gender,
        }
    );

    unless ($booking) {
        warn "Booking datetime is not avaliable: $datetime";
        return;
    }

    my %args = (
        booking_id  => $booking->id,
        wearon_date => $user_info->wearon_date,
        agent       => $extra{agent} || 0,
        ignore      => $extra{ignore} || 0,
        online      => $extra{online} || 0,
    );

    my $guard = $schema->txn_scope_guard;
    my ( $success, $error ) = try {
        ## coupon 중복사용 허용하지 않음
        $self->transfer_order( $extra{coupon}, $order ) if $extra{coupon};
        $order->update( \%args )->discard_changes();
        $self->_update_interview_type( $order, $extra{interview} );
        $guard->commit;
        return 1;
    }
    catch {
        my $err = $_;
        return ( undef, $err );
    };

    unless ($success) {
        warn "update_reservated failed: $error";
        return;
    }

    my $is_jobwing;
    if ( my $coupon = $order->coupon ) {
        my $desc = $coupon->desc || '';
        if ( $desc =~ m/^seoul/ ) {
            $is_jobwing = 1;
            unless ( $extra{skip_jobwing} ) {
                my ( $name, $rent_num, $mbersn ) = split /\|/, $desc;
                my $order_id = $order->id;
                my $client   = OpenCloset::Events::EmploymentWing->new;
                my $success  = $client->update_booking_datetime( $rent_num, $datetime, undef, 1 );
                warn "Failed to update jobwing booking_datetime: rent_num($rent_num), order($order_id), datetime($datetime)"
                    unless $success;
            }
        }
    }

    return 1 unless $self->{sms};

    my $sms = OpenCloset::API::SMS->new( schema => $schema );
    my $mt  = Mojo::Template->new;
    my $tpl = data_section __PACKAGE__, 'booking-datetime-update.txt';
    my $msg = $mt->render(
        $tpl,
        $user->name,
        $datetime->strftime('%m월 %d일 %H시 %M분')
    );
    chomp $msg;
    $sms->send( to => $user_info->phone, msg => $msg );

    return 1;
}

=head2 cancel($order);

C<$order> 를 삭제하고 취소 안내 문자메세지를 보냅니다.

    my $success = $api->cancel($order);

=cut

sub cancel {
    my ( $self, $order ) = @_;
    return unless $order;
    return if $order->status_id != $RESERVATED;

    if ( $self->{sms} ) {
        my $user         = $order->user;
        my $user_info    = $user->user_info;
        my $booking_date = $order->booking->date;
        my $sms          = OpenCloset::API::SMS->new( schema => $self->{schema} );
        my $mt           = Mojo::Template->new;
        my $tpl          = data_section __PACKAGE__, 'booking-cancel.txt';
        my $msg          = $mt->render(
            $tpl,
            $user->name,
            $booking_date->strftime('%m월 %d일 %H시 %M분')
        );
        chomp $msg;
        $sms->send( to => $user_info->phone, msg => $msg );
    }

    $order->delete;
    return 1;
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

셋트여부를 판별해서 타이의 가격을 책정

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
    my $isSuitSet = $self->_is_suit_set(@codes);

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

            my $price = $clothes->price;
            if (!$isSuitSet and $clothes->category eq $TIE) {
                ## https://github.com/opencloset/OpenCloset-API/issues/26
                ## 셋트대여가 아닐때에는 타이의 가격을 2000 으로 책정
                $price = 2_000;
            }
            ## 3회 이상 대여 할인 대상자의 경우 가격이 변경되기 때문에 미리 넣으면 아니됨
            push @order_details, {
                clothes_code     => $code,
                clothes_category => $clothes->category,
                status_id        => $PAYMENT,
                name             => $name,
                price            => $price,
                final_price      => $price,
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
        warn "box2boxed($order_id) failed: $error";
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

        ## 대리인 대여가 아닐때에, 사용자의 신체치수를 복사
        my %size;
        unless ( $order->agent ) {
            map { $size{$_} = $user_info->$_ } qw/height weight neck bust waist hip topbelly belly thigh arm leg knee foot pants skirt/;
        }

        my $comment = $user_info->comment ? $user_info->comment . "\n" : q{};
        my $desc    = $order->desc        ? $order->desc . "\n"        : q{};
        $order->update(
            {
                status_id      => $RENTAL,
                price_pay_with => $price_pay_with,
                rental_date    => $rental_date->datetime,
                purpose        => $user_info->purpose,
                purpose2       => $user_info->purpose2,
                pre_category   => $user_info->pre_category,
                pre_color      => $user_info->pre_color,
                desc           => $comment . $desc,
                %size,
            }
        );
        $order->clothes->update_all( { status_id => $RENTAL } );
        $order->order_details( { clothes_code => { '!=' => undef } } )->update_all( { status_id => $RENTAL } );

        if ( my $coupon = $order->coupon ) {
            if ( $price_pay_with =~ m/쿠폰/ ) {
                my $event = $coupon->event;
                my $cid = $event ? $event->name : $coupon->desc;
                my $coupon_limit = $self->{schema}->resultset('CouponLimit')->find( { cid => $cid } );
                if ($coupon_limit && $event) {
                    my $coupon_count = $self->{schema}->resultset('Coupon')->search(
                        {
                            event_id => $event->id,
                            status   => 'used',
                        },
                    )->count;

                    my $log_str = sprintf(
                        "coupon: code(%s), limit(%d), count(%s)",
                        $order->coupon->code,
                        $coupon_limit->limit,
                        $coupon_count,
                    );
                    if ( $coupon_limit->limit == -1 || $coupon_count < $coupon_limit->limit ) {
                        warn "$log_str\n";
                    }
                    else {
                        die "coupon limit reached: $log_str\n";
                    }
                }

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
        warn "payment2rental($order_id) failed: $error";
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

    my $calc          = OpenCloset::Calculator::LateFee->new;
    my $extension_fee = $calc->extension_fee( $order, $return_date->datetime );
    my $overdue_fee   = $calc->overdue_fee( $order, $return_date->datetime );

    if ( $extension_fee or $overdue_fee ) {
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

        if ($extension_fee) {
            my $extension_days = $calc->extension_days( $order, $return_date->datetime );
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

        if ($overdue_fee) {
            my $overdue_days = $calc->overdue_days( $order, $return_date->datetime );
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
        warn "rental2returned($order_id) failed: $error";
        return;
    }

    $self->notify( $order, $RENTAL, $RETURNED ) if $self->{notify};
    return 1 unless $self->{sms};

    my $user      = $order->user;
    my $user_info = $user->user_info;
    my $sms       = OpenCloset::API::SMS->new( schema => $schema );
    my $mt        = Mojo::Template->new;
    my $section   = $order->online ? 'returned-online-1.txt' : 'returned-1.txt';
    my $tpl       = data_section __PACKAGE__, $section;
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
        warn "rental2partial_returned($order_id) failed: $error";
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
        warn "payment2box($order_id) failed: $error";
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
        warn "rental2payback($order_id) failed: $error";
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
        warn "additional_day($order_id) failed: $error";
        return;
    }

    return 1;
}

=head2 notify( $order, $status_from, $status_to )

    my $res = $self->notify($order, $BOXED, $PAYMENT);

=cut

sub notify {
    my ( $self, $order, $from, $to ) = @_;

    return unless $self->{monitor_uri};
    return unless $order;
    return unless $from;
    return unless $to;

    my $url = sprintf '%s/events', $self->{monitor_uri};
    my $res = $self->{http}->post_form(
        $url,
        {
            sender   => 'order',
            order_id => $order->id,
            from     => $from,
            to       => $to,
        }
    );

    warn "Failed to post event to monitor: ${url}: $res->{reason}" unless $res->{success};
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

=head2 transfer_order( $coupon, $to? )

아직 C<$coupon> 이 사용가능하고 어떤 주문서에 속해 있으면, 해당 주문서에서 쿠폰을 제거하고 중복사용과 관련된 코멘트를 남깁니다.
L<OpenCloset::Schema::Result::Order> 의 object 인 C<$to> 가 정의되어 있다면,
C<$to> 에 C<$coupon> 을 삽입합니다.

    my $success = $api->transfer_order( $coupon );

=head3 Args

=over

=item *

C<$coupon> - L<OpenCloset::Schema::Result::Coupon> object.

=item *

C<$to> - L<OpenCloset::Schema::Result::Order> object.

=back

=cut

sub transfer_order {
    my ( $self, $coupon, $to ) = @_;
    return unless $coupon;

    my $code = $coupon->code;
    my $status = $coupon->status || '';

    if ( $status =~ m/(us|discard|expir)ed/ ) {
        print "Coupon is not valid: $code($status)";
        return;
    }
    elsif ( $status eq 'reserved' ) {
        my $orders = $coupon->orders;
        unless ( $orders->count ) {
            print "It is reserved coupon, but the order can not be found: $code";
        }

        my @orders;
        while ( my $order = $orders->next ) {
            my $order_id  = $order->id;
            my $coupon_id = $order->coupon_id;
            printf( "Delete coupon_id(%d) from existing order(%d): %s", $order->coupon_id, $order->id, $code );

            my $return_memo = $order->return_memo;
            $return_memo .= "\n" if $return_memo;
            $return_memo .= sprintf(
                "쿠폰의 중복된 요청으로 주문서(%d) 에서 쿠폰(%d)이 삭제되었습니다: %s",
                $order->id, $order->coupon_id, $code
            );
            $order->update( { coupon_id => undef, return_memo => $return_memo } );

            push @orders, $order->id;
        }

        if ($to) {
            my $return_memo = $to->return_memo;
            if (@orders) {
                printf( "Now, use coupon(%d) in order(%d) %s instead", $coupon->id, $to->id, join( ', ', @orders ) );

                $return_memo .= "\n" if $return_memo;
                $return_memo .= sprintf(
                    "%s 에서 사용된 쿠폰(%d)이 주문서(%d)에 사용됩니다: %s",
                    join( ', ', @orders ),
                    $coupon->id, $to->id, $code
                );
            }
            else {
                printf( "Now, use coupon(%d) in order(%d)", $coupon->id, $to->id );
            }

            $to->update( { coupon_id => $coupon->id, return_memo => $return_memo } );
        }
    }
    elsif ( $status eq 'provided' || $status eq '' ) {
        $coupon->update( { status => 'reserved' } );
        if ($to) {
            printf( "Now, use coupon(%d) in order(%d)", $coupon->id, $to->id );
            $to->update( { coupon_id => $coupon->id } );
        }
    }

    return 1;
}

=head2 take_booking_slot_if_available($datetime, $gender)

해당 시간의 C<$gender> 의 예약 슬롯이 없을때에, 다른 성별의 예약 슬롯을
하나 가져옵니다.

=head3 return

return true if take, otherwise false.

=head3 arguments

=over

=item *

C<$datetime>

L<DateTime> object

=item *

C<$gender>

C<male> or C<female>

=back

=cut

sub take_booking_slot_if_available {
    my ($self, $datetime, $gender) = @_;

    my %map = (
        female => 'male',
        male   => 'female',
    );

    my $schema = $self->{schema};
    my $booking = $schema->resultset('Booking')->find(
        {
            date   => "$datetime",
            gender => $gender
        }
    );

    return unless $booking;

    my $reservated = $schema->resultset('Order')->search({ booking_id => $booking->id })->count;

    my $slot = $booking->slot;
    return if $slot > $reservated;    # 아직 slot 이 남아있음

    my $other_booking = $schema->resultset('Booking')->find(
        {
            date   => "$datetime",
            gender => $map{$gender}
        }
    );

    return unless $other_booking;

    my $other_slot = $other_booking->slot;
    my $other_reservated = $schema->resultset('Order')->search({ booking_id => $other_booking->id })->count;
    my $buffer = $other_slot - $other_reservated;
    return if $buffer <= 1;    # 하나 남은건 못 준다.

    $booking->update({ slot => $slot + 1 });
    $other_booking->update({ slot => $other_slot - 1 });
    return 1;
}

=head2 _is_suit_set(@codes)

C<@codes> 는 의류코드 (e.g 0J001, ..)

의류코드로 셋트대여인지 여부를 판별해줍니다.
자켓+팬츠가 포함된 경우에는 셋트대여입니다.

=cut

sub _is_suit_set {
    my ($self, @codes) = @_;
    return unless @codes;

    my $hasJacket = grep { /^0?J/i } @codes;
    my $hasPants = grep { /^0?P/i } @codes;
    return $hasJacket && $hasPants;
}

#
# GH #1684
#   화상면접인 경우 주문서에 태그를 추가하거나 제거함
#
sub _update_interview_type {
    my ( $self, $order, $interview ) = @_;

    my $schema = $self->{schema};

    my $online_tag = $schema->resultset("Tag")->find_or_create({ name => "화상면접" });
    return unless $online_tag;

    my $online_order_tag = $order->order_tags->search({ tag_id => $online_tag->id })->next;
    {
        use experimental qw( smartmatch switch );
        given ($interview) {
            when ("online") {
                # 주문서에 화상면접 태그 추가
                unless ($online_order_tag) {
                    $schema->resultset("OrderTag")->create(
                        {
                            order_id => $order->id,
                            tag_id   => $online_tag->id,
                        }
                    );
                }
            }
            default {
                # 주문서에 화상면접 태그 제거
                if ($online_order_tag) {
                    $online_order_tag->delete;
                }
            }
        }
    }
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

[택배대여 안내] 다음에는 집에서 편하게 온라인으로 주문하세요.
http://share.theopencloset.net/welcome  클릭하여 신청하시면 됩니다.

[청년정보 안내] 청년과 취업을 응원하는 다양한 프로그램 진행 중입니다.
열린옷장 SNS를 팔로우하면 놓치지 않고 받을 수 있습니다.
https://www.instagram.com/opencloset_people/
https://www.facebook.com/TheOpenCloset/

@@ returned-online-1.txt
% my ($order, $user) = @_;
[열린옷장] <%= $user->name %>님의 의류가 정상적으로 반납되었습니다. 감사합니다.
택배대여 중 불편하셨던 점 많으셨죠? 개선을 위한 설문조사입니다. 작성해주시면 꼭 반영하겠습니다. https://bit.ly/2Mv1Ipr

@@ order-reserved-1.txt
% my ($order, $name, $datetime, $edit_url) = @_;
[열린옷장] <%= $name %>님 <%= $datetime %>으로 방문 예약이 완료되었습니다.
<열린옷장 위치안내>
서울특별시 광진구 아차산로 213 국민은행, 건대입구역 1번 출구로 나오신 뒤 오른쪽으로 꺾어 150M 가량 직진하시면 1층에 국민은행이 있는 건물 5층으로 올라오시면 됩니다. (도보로 약 3분 소요)
지도 안내: https://goo.gl/UuJyrx

예약시간 변경/취소는 <%= $edit_url %> 에서 가능합니다.

1. 지각은 NO!
꼭 예약 시간에 방문해주세요. 예약한 시간에 방문하지 못한 경우, 정시에 방문한 대여자를 먼저 안내하기 때문에 늦거나 일찍 온 시간만큼 대기시간이 길어집니다.

2. 노쇼(no show)금지
열린옷장은 하루에 방문 가능한 예약 인원이 정해져 있습니다. 방문이 어려운 경우 다른 분을 위해 반드시 '예약취소' 해주세요. 예약취소는 세 시간 전까지 가능합니다.

@@ employment-wing.txt
% my ($year) = @_;
[열린옷장] <%= $year %> 취업날개 서비스

올해 면접정장 무료대여는 '서울시' 거주 중인 고교졸업예정자~34세를 대상으로 합니다. 아래 거주지 증빙 미지참시 무료 대여가 되지 않습니다.

1. 주민등록상 서울시 거주자인 경우 : 서울시 주소와 나이를 증명할 수 있는 신분증(주민등록증, 운전면허증, 등본)
2. 서울소재 학교 재학생/졸업생인 경우 : 학생증/졸업증명서 + 서울거주 증명서류(본인명의 계약서, 수도전기 고지서 등)

매회 이용시 증빙이 필요하며, 이용조건 증빙이 없는 경우 무료대여 서비스를 이용할 수 없음을 거듭 안내드립니다. 감사합니다.

@@ booking-cancel.txt
% my ($name, $datetime) = @_;
[열린옷장] <%= $name %>님 <%= $datetime %> 방문 예약이 취소되었습니다.

@@ booking-datetime-update.txt
% my ($name, $datetime) = @_;
[열린옷장] <%= $name %>님 <%= $datetime %>으로 방문 예약이 변경되었습니다.

@@ employment-wing-target.txt
[열린옷장] 서울시 무료대여 정보알림
현재 서울시 청년을 위한 연 10회 무료 정장대여 "취업날개 서비스" 진행중입니다. 주소지, 입사면접 증빙 등 자격요건과 필요서류를 확인하시고 소중한 혜택을 누리시기 바랍니다.

서울시 취업날개 바로가기 => http://bitly.kr/yw53
