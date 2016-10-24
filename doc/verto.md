# VERTO Plugin

NkCOLLAB includes a [Verto](http://evoluxbr.github.io/verto-docs/) compatible server, meaning that you can use any Verto client, like [Verto Communicator](https://freeswitch.org/confluence/display/FREESWITCH/Verto+Communicator) to connect to NkCOLLAB and place and receive calls.

Verto clients can be used with or withouth Freeswtich backend, since NkCOLLAB includes a full Verto server (like Freeswitch does).

To use it, your service must include the [nkmedia_verto](../src/plugins/nkmedia_verto.erl) plugin. The following configuration options are available:

Option|Sample|Description
---|---|---
verto_listen|"verto:all:8082"|Interface and port to listen on

Once started, when a new Verto connection arrives, the callback `nkmedia_verto_login/3` would be called. (See [nkmedia_verto_callbacks.erl](../src/plugins/nkmedia_verto_callbacks.erl)), so you can authorize the request.

To call to a Verto destination, you must use NkCOLLAB's built-in calling facility. You must use call type `verto`, and `callee` must point to the called user.

When a Verto sessions starts a new call, the default processing is based on the called destination:

Destination|Sample|Description
---|---|---
p2p:...|p2p:1008|Peer to Peer call
verto:...|verto:1008|Verto-to-Verto call
sip:...|sip:103|SIP call
...|1008|User call

For _p2p_ calls, a session will be started (with `p2p` type), and a new call with type `user`. The selected user will receive the call with the original SDP from Verto, so it will be a _peer to peer_ call.

For _verto_ calls, a session is started with `user` type, but only verto users are selected. Also, the call is sent through a Janus proxy, and it is sent using native Verto signaling.

For _sip_ calls, the selected destination will be searched to see if it is already registered (if the domain is not used, the default in config is used). Full sip addresses can also be used. A `proxy` session will be started, converting Verto's WebRTC to an SDP-compatible one.

If no prefix is used, a Janus webrtc-to-webrtc proxy and a call with type `user` is started, and the user is searched on all plugins.

