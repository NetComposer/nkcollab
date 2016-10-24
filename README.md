
# NkCOLLAB

**IMPORTANT** NkCOLLAB is still under development, and not yet ready for general use.

NkCOLLAB is an scalable and flexible signaling and media server for WebRTC and SIP, designed to add signaling capabilities to [NkMEDIA](https://github.com/NetComposer/nkmedia). Currently, it supports two applications:

* Hangouts-type [**video room**](doc/room.md) management
* PBX-type [**calling**](doc/call.md), using three different API:
	* its [own signaling system](doc/call.md). 
	* a full **SIP** implementation (based on [NkSIP](https://github.com/NetComposer/nksip), so it can be a flexible, massively scalable SIP client and server). It is also very easy to develop scalable SIP/Webrtc gateways using the Call subsystem.
	* a [Verto](http://evoluxbr.github.io/verto-docs/) server implementation (that can be used with any backend, not only Freeswitch)

It also possible to add new signaling APIs, or use your own signalling solution out of NkCOLLAB.

NkMEDIA can be managed using [NetComposer API](https://github.com/NetComposer/nkservice/blob/luerl/doc/api_intro.md). In real-life deployments, you will typically connect a server-side application to the management interface. However, being a websocket connection, you can also use a browser to manage sessions (its own or any other's session, if it is authorized).

## Features
* Full support for WebRTC and SIP.
* Full support for complex SIP scenarios: stateful proxies with serial and parallel forking, stateless proxies, B2BUAs, application servers, registrars, SBCs, load generators, etc.
* WebRTC P2P calls.
* Proxied (server-through) calls (including SIP/WebRTC gateways, with or without transcoding).
* Full Trickle ICE support. Connect trickle and non-trickle clients and backends automatically.
* Abstract API, independant of every specific backend.
* Robust and highly scalable, using all available processor cores automatically.
* Sophisticated plugin mechanism, that adds very low overhead to the core.
* Hot, on-the-fly core and application configuration and code upgrades.


## Documentation

* [Room application](doc/room.md)
* [Call application](doc/call.md)
* [SIP plugin](doc/sip.md)
* [Verto plugin](doc/verto.md)

See also [NkMEDIA documentation](https://github.com/NetComposer/nkmedia).


## Installation

Currently, NkCOLLAB is only available in source form. To build it, you only need Erlang (> r17). 
To run NkCOLLAB, you also need also Docker (>1.6). The docker daemon must be configured to use TCP/TLS connections.

```
git clone https://github.com/NetComposer/nkcollab
cd nkcollab
make
```







