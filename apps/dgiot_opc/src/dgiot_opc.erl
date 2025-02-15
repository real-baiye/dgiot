%%--------------------------------------------------------------------
%% Copyright (c) 2020 DGIOT Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(dgiot_opc).
-author("johnliu").
-include_lib("dgiot/include/logger.hrl").

-export([
    scan_opc/1,
    read_opc/4,
    process_opc/2,
    read_opc_ack/4,
    scan_opc_ack/3,
    create_changelist/1,
    create_final_Properties/1,
    create_x_y/1,
    change_config/1,
    create_config/1
]).


%% 下发扫描OPC命令
%% topic: dgiot_opc_da
%% payload：
%%{
%%"cmdtype":"scan",
%%"opcserver":"Kepware.KEPServerEX.V6"
%%}
scan_opc(#{<<"OPCSEVER">> := OpcServer}) ->
    Payload = #{
        <<"cmdtype">> => <<"scan">>,
        <<"opcserver">> => OpcServer
    },
    dgiot_mqtt:publish(<<"opcserver">>, <<"dgiot_opc_da">>, jsx:encode(Payload)).

read_opc(ChannelId, OpcServer, DevAddr, Instruct) ->
    Payload = #{
        <<"cmdtype">> => <<"read">>,
        <<"opcserver">> => OpcServer,
        <<"group">> => DevAddr,
        <<"items">> => Instruct
    },
    dgiot_bridge:send_log(ChannelId, "to_opc: ~p: ~p  ~ts ", [OpcServer, DevAddr, unicode:characters_to_list(Instruct)]),
    dgiot_mqtt:publish(<<"opcserver">>, <<"dgiot_opc_da">>, jsx:encode(Payload)).

scan_opc_ack(Payload, OpcServer, DevAddr) ->            %%---------- 用以创建组态、物模型。
    Map = jsx:decode(Payload, [return_maps]),
    Instruct = maps:fold(fun(K, V, Acc) ->
        IsSystem = lists:any(fun(E) ->
            lists:member(E, [<<"_System">>, <<"_Statistics">>, <<"_ThingWorx">>, <<"_DataLogger">>])
                             end, binary:split(K, <<$.>>, [global, trim])),
        case IsSystem of
            true ->
                Acc;
            false ->
                lists:foldl(fun(X, Acc1) ->
                    case X of
                        #{<<"ItemId">> := ItemId} ->
                            case binary:split(ItemId, <<$.>>, [global, trim]) of
                                [_Project, _Device, Id] ->
                                    case binary:split(Id, <<$_>>, [global, trim]) of
                                        [Id] ->
                                            get_instruct(Acc1, ItemId);
                                        _ ->
                                            Acc1
                                    end;
                                [_Project, _Device, _Id, Type] ->
                                    case lists:member(Type, [<<"_Description">>, <<"_RawDataType">>]) of
                                        true ->
                                            get_instruct(Acc1, ItemId);
                                        false ->
                                            Acc1
                                    end;
                                _ -> Acc1
                            end;
                        _ ->
                            Acc1
                    end
                            end, Acc, V)
        end
                         end, <<"">>, maps:without([<<"status">>], Map)),
    Payload1 = #{
        <<"cmdtype">> => <<"read">>,
        <<"opcserver">> => OpcServer,
        <<"group">> => DevAddr,
        <<"items">> => Instruct
    },

    dgiot_mqtt:publish(<<"opcserver">>, <<"dgiot_opc_da">>, jsx:encode(Payload1)).




get_instruct(Acc1, ItemId) ->
    case Acc1 of
        <<"">> ->
            ItemId;
        _ ->
            <<Acc1/binary, ",", ItemId/binary>>
    end.

read_opc_ack(Payload, ProductId, DeviceId, Devaddr) ->
    case jsx:decode(Payload, [return_maps]) of
        #{<<"status">> := 0} = Map0 -> %% opc read的情况
            [Map1 | _] = maps:values(maps:without([<<"status">>], Map0)),
            case maps:find(<<"status">>, Map1) of
                {ok, _} ->
                    [Map2 | _] = maps:values(maps:without([<<"status">>], Map1));
                error ->
                    Map2 = Map1

            end,

            %%  -------------------------------- 组态数据传递
            dgiot_product:load(ProductId),
            Data = maps:fold(fun(K, V, Acc) ->
                case binary:split(K, <<$.>>, [global, trim]) of
                    [_, _, K1] ->
                        Name =
                            case dgiot_product:lookup_prod(ProductId) of
                                {ok, #{<<"thing">> := #{<<"properties">> := Properties}}}
                                    ->
                                    ALL_list = [{maps:get(<<"identifier">>, H), maps:get(<<"name">>, H)} || H <- Properties],
                                    proplists:get_value(K1, ALL_list);
                                _ ->
                                    <<" ">> end,

                        Unit =
                            case dgiot_product:lookup_prod(ProductId) of
                                {ok, #{<<"thing">> := #{<<"properties">> := Properties1}}}
                                    ->
                                    ALL_list1 = [{maps:get(<<"identifier">>, H), maps:get(<<"dataType">>, H)} || H <- Properties1],
                                    Map_datatype = proplists:get_value(K1, ALL_list1),
                                    Specs = maps:get(<<"specs">>, Map_datatype),
                                    maps:get(<<"unit">>, Specs);
                                _ ->
                                    <<" ">> end,

                        V1 = binary:bin_to_list(Name),
                        V2 = dgiot_utils:to_list(V),
                        V1_unit = dgiot_utils:to_list(Unit),
                        V3 = V1 ++ ": " ++ V2 ++ " " ++ V1_unit,
                        Acc#{K => V3};
                    _ -> Acc
                end
                             end, #{}, Map2),
            Data2 = maps:fold(fun(K, V, Acc) ->
                case binary:split(K, <<$.>>, [global, trim]) of
                    [_, _, K1] ->
                        Acc#{K1 => V};
                    _ -> Acc
                end
                              end, #{}, Map2),
            dgiot_topo:push(ProductId, Devaddr, DeviceId, Data),
%%  -------------------------------- 设备上线状态修改
            case dgiot_data:get({dev, status, DeviceId}) of
                not_find ->
                    dgiot_data:insert({dev, status, DeviceId}, self()),
                    dgiot_parse:update_object(<<"Device">>, DeviceId, #{<<"status">> => <<"ONLINE">>});
                _ -> pass

            end,
%% --------------------------------  数据存TD库
            dgiot_tdengine_adapter:save(ProductId, Devaddr, Data2);

        _ ->
            pass
    end.

process_opc(ChannelId, Payload) ->
    [DevAddr | _] = maps:keys(Payload),
    Items = maps:get(DevAddr, Payload, #{}),
    case dgiot_data:get({dgiot_opc, DevAddr}) of
        not_find ->
            pass;
        ProductId ->
            NewTopic = <<"thing/", ProductId/binary, "/", DevAddr/binary, "/post">>,
            dgiot_bridge:send_log(ChannelId, "to_task: ~ts", [unicode:characters_to_list(jsx:encode(Items))]),
            dgiot_mqtt:publish(DevAddr, NewTopic, jsx:encode(Items))
%%        _ -> pass
    end.


%%scan后创建物模型
create_Properties({Item, RawDataType, Description, Scan_instruct}) ->
    DataType =
        case RawDataType of
            <<"Boolean">> ->
                <<"bool">>;
            <<"Char">> ->
                <<"string">>;
            <<"Byte">> ->
                <<"string">>;
            <<"Short">> ->
                <<"int">>;
            <<"Word">> ->
                <<"string">>;
            <<"Long">> ->
                <<"int">>;
            <<"DWord">> ->
                <<"string">>;
            <<"LLong">> ->
                <<"string">>;
            <<"QWord">> ->
                <<"string">>;
            <<"Float">> ->
                <<"float">>;
            <<"Double">> ->
                <<"double">>;
            <<"String">> ->
                <<"string">>;
            <<"Date">> ->
                <<"date">>;
            _ ->
                <<"string">>
        end,
    #{<<"accessMode">> => <<"r">>,
        <<"dataForm">> =>
        #{<<"address">> => Scan_instruct,
            <<"byteorder">> => <<"big">>,
            <<"collection">> => <<"%s">>,
            <<"control">> => <<"%d">>, <<"data">> => <<"null">>,
            <<"offset">> => 0, <<"protocol">> => <<"normal">>,
            <<"quantity">> => <<"null">>, <<"rate">> => 1,
            <<"strategy">> => <<"20">>},
        <<"dataType">> =>
        #{<<"specs">> =>
        #{<<"max">> => 1000, <<"min">> => -1000,
            <<"step">> => 0.01, <<"unit">> => <<" ">>},
            <<"type">> => DataType},
        <<"identifier">> => Item,
        <<"name">> => Description,
        <<"required">> => true}.



create_final_Properties(List) -> [create_Properties(X) || X <- List].


%%%创建组态config
create_config(List) ->
    #{<<"konva">> =>
    #{<<"Stage">> =>
    #{<<"attrs">> =>
    #{<<"draggable">> => true, <<"height">> => 469,
        <<"id">> => <<"container">>, <<"width">> => 1868,
        <<"x">> => 14, <<"y">> => 29},
        <<"children">> =>
        [#{<<"attrs">> =>
        #{<<"id">> => <<"Layer_sBE2t0">>},
            <<"children">> =>
            [#{<<"attrs">> =>
            #{<<"height">> => 2000,
                <<"id">> => <<"Group_9H6kPPA">>,
                <<"width">> => 2000},
                <<"children">> => List,              %%%组态按钮标签
                <<"className">> => <<"Group">>}],
            <<"className">> => <<"Layer">>}],
        <<"className">> => <<"Stage">>}}}.


%%创建组态按钮标签List->{text}





create_lable({{_, _, Description, Scan_Instruct}, {X, Y}}) ->
    #{<<"attrs">> =>
    #{
        <<"draggable">> => true,
        <<"fill">> => <<"#000000">>,
        <<"fontFamily">> => <<"Calibri">>,
        <<"fontSize">> => 20,
        <<"id">> => Scan_Instruct,
        <<"text">> => Description, %% 太阳能板电压
        <<"type">> => <<"text">>,
        <<"x">> => X,
        <<"y">> => Y},
        <<"className">> => <<"Text">>}.



change_config(List) ->
    [create_lable(X) || X <- List].

create_x_y(Num) when Num > 0 -> %% 根据属性个数生成合理的（x,y)坐标
    [{((Num - 1) div 5) * 300 + 100, 50 + 150 * ((Num - 1) rem 5)} | create_x_y(Num - 1)];
create_x_y(0) -> [].



create_changelist(List_Data) ->
    Item = [{K, V} || {K, V} <- List_Data, jud1(K)],
    RawDataType = [{K, V} || {K, V} <- List_Data, jud2(K)],
    Description = [{K, V} || {K, V} <- List_Data, jud3(K)],
    Scan_instruct = [{K, V} || {K, V} <- List_Data, jud4(K)],
%%    ?LOG(info,"Scan_instruct:~p",[RawDataType]),
    [{Item1, RawDataType1, Description1, Scan_instruct1} || {K1, Item1} <- Item, {K2, RawDataType1} <- RawDataType, {K3, Description1} <- Description, {K4, Scan_instruct1} <- Scan_instruct, jud(K1, K2, K3, K4)].

jud1(X) ->
    case binary:split(X, <<$_>>, [global, trim]) of
        [X] ->
            true;
        _ ->
            false
    end.

jud2(X) ->
    case binary:split(X, <<$_>>, [global, trim]) of
        [_, <<"RawDataType">>] ->
            true;
        _ ->
            false
    end.

jud3(X) ->
    case binary:split(X, <<$_>>, [global, trim]) of
        [_, <<"Description">>] ->
            true;
        _ ->
            false
    end.

jud4(X) ->
    case binary:split(X, <<$.>>, [global, trim]) of
        [_, _, _] ->
            true;
        _ ->
            false
    end.

jud(K1, K2, K3, K4) ->
    [Key2, _] = binary:split(K2, <<$_>>, [global, trim]),
    [Key3, _] = binary:split(K3, <<$_>>, [global, trim]),
    [_, _, Key4] = binary:split(K4, <<$.>>, [global, trim]),
%%    ?LOG(info,"------------Key:~p",[Key4]),
    case Key2 == Key3 of
        true ->
            case K1 == Key2 of
                true ->
                    case K1 == Key4 of
                        true ->
                            true;
                        false ->
                            false
                    end;
                false ->
                    false
            end;
        false ->
            false
    end.
