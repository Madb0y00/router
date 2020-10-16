-module(router_device_utils).

-export([report_frame_status/10,
         report_status/11,
         report_status_max_size/3,
         report_status_no_dc/1,
         report_status_inactive/1,
         report_join_status/4,
         get_router_oui/0,
         mtype_to_ack/1]).

-include("lorawan_vars.hrl").
-include("device_worker.hrl").

-spec report_frame_status(integer(), boolean(), any(), libp2p_crypto:pubkey_bin(), atom(),
                          router_device:device(), blockchain_helium_packet_v1:packet(),
                          binary() | undefined, #frame{}, blockchain:blockchain()) -> ok.
report_frame_status(0, false, 0, PubKeyBin, Region, Device, Packet, ReplyPayload, #frame{devaddr=DevAddr, fport=FPort}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Correcting channel mask in response to ", (int_to_bin(FCnt))/binary>>,
    ok = ?MODULE:report_status(down, Desc, Device, success, PubKeyBin, Region, Packet, ReplyPayload, FPort, DevAddr, Blockchain);
report_frame_status(1, _ConfirmedDown, undefined, PubKeyBin, Region, Device, Packet, ReplyPayload, #frame{devaddr=DevAddr, fport=FPort}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = ?MODULE:report_status(ack, Desc, Device, success, PubKeyBin, Region, Packet, ReplyPayload, FPort, DevAddr, Blockchain);
report_frame_status(1, true, Port, PubKeyBin, Region, Device, Packet, ReplyPayload, #frame{devaddr=DevAddr}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK and confirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = ?MODULE:report_status(ack, Desc, Device, success, PubKeyBin, Region, Packet, ReplyPayload, Port, DevAddr, Blockchain);
report_frame_status(1, false, Port, PubKeyBin, Region, Device, Packet, ReplyPayload, #frame{devaddr=DevAddr}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending ACK and unconfirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = ?MODULE:report_status(ack, Desc, Device, success, PubKeyBin, Region, Packet, ReplyPayload, Port, DevAddr, Blockchain);
report_frame_status(_, true, Port, PubKeyBin, Region, Device, Packet, ReplyPayload, #frame{devaddr=DevAddr}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending confirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = ?MODULE:report_status(down, Desc, Device, success, PubKeyBin, Region, Packet, ReplyPayload, Port, DevAddr, Blockchain);
report_frame_status(_, false, Port, PubKeyBin, Region, Device, Packet, ReplyPayload, #frame{devaddr=DevAddr}, Blockchain) ->
    FCnt = router_device:fcnt(Device),
    Desc = <<"Sending unconfirmed data in response to fcnt ", (int_to_bin(FCnt))/binary>>,
    ok = ?MODULE:report_status(down, Desc, Device, success, PubKeyBin, Region, Packet, ReplyPayload, Port, DevAddr, Blockchain).

-spec report_status(atom(), binary(), router_device:device(), success | error,
                    libp2p_crypto:pubkey_bin(), atom(), blockchain_helium_packet_v1:packet(),
                    binary() | undefined, any(), any(), blockchain:blockchain()) -> ok.
report_status(Category, Desc, Device, Status, PubKeyBin, Region, Packet, ReplyPayload, Port, DevAddr, Blockchain) ->
    Payload = case ReplyPayload of
                  undefined -> blockchain_helium_packet_v1:payload(Packet);
                  _ -> ReplyPayload
              end,
    Report = #{category => Category,
               description => Desc,
               reported_at => erlang:system_time(seconds),
               payload => base64:encode(Payload),
               payload_size => erlang:byte_size(Payload),
               port => Port,
               devaddr => lorawan_utils:binary_to_hex(DevAddr),
               hotspots => [router_utils:format_hotspot(Blockchain, PubKeyBin, Packet, Region, erlang:system_time(seconds), Status)],
               channels => []},
    ok = router_device_api:report_status(Device, Report).

-spec report_status_max_size(router_device:device(), binary(), non_neg_integer()) -> ok.
report_status_max_size(Device, Payload, Port) ->
    Report = #{category => packet_dropped,
               description => <<"Packet request exceeds maximum 242 bytes">>,
               reported_at => erlang:system_time(seconds),
               payload => base64:encode(Payload),
               payload_size => erlang:byte_size(Payload),
               port => Port,
               devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
               hotspots => [],
               channels => []},
    ok = router_device_api:report_status(Device, Report).

-spec report_status_no_dc(router_device:device()) -> ok.
report_status_no_dc(Device) ->
    Report = #{category => packet_dropped,
               description => <<"Not enough DC">>,
               reported_at => erlang:system_time(seconds),
               payload => <<>>,
               payload_size => 0,
               port => 0,
               devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
               hotspots => [],
               channels => []},
    ok = router_device_api:report_status(Device, Report).

-spec report_status_inactive(router_device:device()) -> ok.
report_status_inactive(Device) ->
    Report = #{category => packet_dropped,
               description => <<"Transmission has been paused. Contact your administrator">>,
               reported_at => erlang:system_time(seconds),
               payload => <<>>,
               payload_size => 0,
               port => 0,
               devaddr => lorawan_utils:binary_to_hex(router_device:devaddr(Device)),
               hotspots => [],
               channels => []},
    ok = router_device_api:report_status(Device, Report).

report_join_status(Device, {_, PubKeyBinSelected, _}=PacketSelected, Packets, Blockchain) ->
    DevEUI = router_device:dev_eui(Device),
    AppEUI = router_device:app_eui(Device),
    DevAddr = router_device:devaddr(Device),
    Desc = <<"Join attempt from AppEUI: ", (lorawan_utils:binary_to_hex(AppEUI))/binary, " DevEUI: ",
             (lorawan_utils:binary_to_hex(DevEUI))/binary>>,
    Hotspots = lists:foldl(
                 fun({Packet, PubKeyBin, Region}, Acc) ->
                         H = router_utils:format_hotspot(Blockchain, PubKeyBin, Packet, Region, erlang:system_time(seconds), <<"success">>),
                         [maps:put(selected, PubKeyBin == PubKeyBinSelected, H)|Acc]
                 end,
                 [],
                 [PacketSelected|Packets]),
    Report = #{category => activation,
               description => Desc,
               reported_at => erlang:system_time(seconds),
               payload => <<>>,
               payload_size => 0,
               port => 0,
               fcnt => 0,
               devaddr => lorawan_utils:binary_to_hex(DevAddr),
               hotspots => Hotspots,
               channels => []},
    ok = router_device_api:report_status(Device, Report).

-spec get_router_oui() -> non_neg_integer().
get_router_oui() ->
    case application:get_env(router, oui, undefined) of
        undefined ->
            undefined;
        OUI0 when is_list(OUI0) ->
            list_to_integer(OUI0);
        OUI0 ->
            OUI0
    end.

-spec mtype_to_ack(integer()) -> 0 | 1.
mtype_to_ack(?CONFIRMED_UP) -> 1;
mtype_to_ack(_) -> 0.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec int_to_bin(integer()) -> binary().
int_to_bin(Int) ->
    erlang:list_to_binary(erlang:integer_to_list(Int)).