# SIP Plugin


nkCOLLAB includes a full blown SIP server, based on [NkSIP](https://github.com/NetComposer/nksip), so it is extremely flexible and scalable. It can be used to make SIP gateways or any other SIP entity. It also includes a registrar server.

To use it, your service must include the [nkmedia_sip](../src/plugins/nkmedia_sip.erl) plugin. The following configuration options are available:

Option|Sample|Description
---|---|---
sip_listen|"sip:all:5060|Interface and port to listen on (sips and tcp/tls can be used)
sip_registrar|true|Accept incoming REGISTER
sip_domain|"nkmedia"|Default SIP domain
sip_registrar_force_domain|true|Force each incoming REGISTER as having default domain
sip_invite_not_registered|true|Allow INVITEs to unregistered SIP endpoints

To call to a SIP destination, you must use nkCOLLAB's built-in calling facility. You must use call type `sip`, and `callee` must point to the called destination. It can be a registered endpoint, or a full SIP address.

When a new SIP connection arrives, the callback `nkmedia_sip_invite/5` would be called. (See [nkmedia_sip_callbacks.erl](../src/plugins/nkmedia_sip_callbacks.erl)). The default processing is based on the called destination:

Destination|Sample|Description
---|---|---
p2p:...|p2p:123|Peer to Peer call
verto:...|verto:1008|SIP-to-Verto call
...|1008|SIP-to-WebRTC User call

For _p2p_ calls, a session will be started (with `p2p` type), and a new call with type `user`. The selected user will receive the call with the original SDP from Verto, so it will be a _peer to peer_ call.

If no prefix is used, a session is started with `user` type. The call is sent through a Janus proxy, that will adapt SIP's SDP to a WebRTC-compatile one. Registered users will receive the INVITE.

For _verto_ calls, it is similar, but only Verto users will receive the call, using native Verto signaling.

