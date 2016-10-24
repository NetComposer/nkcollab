# CALL Application


This plugin offers an easy to use signalling on top of NkCOLLAB, so that you can send _calls_ from any supported client to any other supported endpoint.

You can call from a registered user, SIP endpoint or Verto session to any other of them. You only need to supply the _offer_ and destination, and NkCOLLAB will locate all endpoints beloging to that destination, and wilk start parallel sessions for all of them. The first one that answers is connected to the caller. 

* [**Commands**](#commands)
  * [`create`](#create): Create a new call
  * [`hangup`](#hangup): Destroys a call
  * [`ringing`](#ringing): Signals that a callee is ringing
  * [`rejected`](#rejected): Signals that a callee has rejected the call
  * [`accepted`](#accepted): Signals that a callee has accepted the call
  * [`set_candidate`](#set_candidate): Sends a Trickle ICE candidate
  * [`set_candidate_end`](#set_candidate): Signals end of Trickle ICE candidates
* [**Events**](#events)
* [**Destinations**](#destinations)


All commands must have 

```js
{
  class: "collab",
  subclass: "call"
}
```

See also each backend documentation:

* [nkmedia_janus](janus.md#calls)
* [nkmedia_fs](fs.md#calls)
* [nkmedia_kms](kms.md#calls)

Also, for Erlang developers, you can have a look at the command [syntax specification](../src/nkcollab_call_api_syntax.erl) and [command implementation](../src/nkcollab_call_api.erl).


# Commands

## create

Starts a new call. You must supply a `callee` and an `offer`. Available fields are:

Field|Default|Description
---|---|---
call_id|(generated)|Call ID
callee|(mandatory)|Callee specification (see [destinations](#destinations))
offer|(mandatory)|Offer to use
type|(mandatory)|Call type (see [destinations](#destinations))
caller|{}|Caller specification (for notifications)
backend|p2p|Backend to use (see each backend documentation)
no_offer_trickle_ice|false|Forces consolidation of offer candidates in SDP
no_answer_trickle_ice|false|Forces consolidation of answer candidates in SDP
trickle_ice_timeout|5000|Timeout for Trickle ICE before consolidating candidates
sdp_type|"webrtc"|Type of offer or answer SDP to generate (`webrtc` or `rtp`)
subscribe|true|Subscribe to call events. Use `false` to avoid automatic subscription.
event_body|{}|Body to receive in all automatic events.

NkCOLLAB will create a _caller_ media session (type will be dependant of plugin). Some plugins will offer the answer inmediately, while other will need the answer from the remote party.

NkCOLLAB will then _resolve_ the callee to a set of [destinations](#destinations), starting a new session for each and calling each one in parallel. Each callee can use the [`ringing`](#ringing), [`rejected`](#rejected) and [`accepted`](#accepted) commands.


**Sample**

```js
{
	class: "collab",
	subclass: "call"
	cmd: "create",
	data: {
		type: "user",
		callee: "user@domain.com"
		offer: { 
			sdp: "v=0.." 
		},
		caller: {
			name: "my name"
		},
		backend: "nkmedia_janus"

	}
	tid: 1
}
```
-->
```js
{
	result: "ok",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
	},
	tid: 1
}
```


NkCOLLAB will locate all destinations (for example, por _user_ type, locating all sessions belongig to the user) and will send an _invite_ to each of them in parallel scheme with its offer.

You must reply inmediately (before prompting the user or ringing) either accepting the call (returning `result: "ok"`) or rejecting it with `result: "error"`. From all accepted calls, it is expected that the callee must call [`rejected`](#rejected) or [`accepted`](#accepted).


```js
{
	class: "collab",
	subclass: "call",
	cmd: "invite",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		type: "user",
		offer: {
			sdp: "v=0..",
		},
		caller: {
			name: "my name"
		},
		session_id: "c666c860-3e99-a853-a83c-38c9862f00d9"
	},
	tid: 1000
}
```

-->

```js
{
	result: "ok",
	data: {
		subscribe: true
	},
	tid: 1000
}
```



If you reply `accepted`, you can also include the following fields:

Field|Default|Description
---|---|---|---
call_id|(mandatory)|Call ID
subscribe|true|Subscribe automatically to call events for this call
event_body|{}|Body to receive in the automatic events.

Also, you have to be prepared to receive a hangup event at any moment, even before accepting the call:

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "collab",
		subclass: "call",
		type: "hangup",
		obj_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		body: {							
			code: 0
			error: "User Rejected"
		}
	tid: 1001
}
```


## hangup

Destroys a current call. 

Field|Default|Description
---|---|---
call_id|(mandatory)|Call ID
reason|-|Optional reason (text)


## ringing

Notify call ringing

After receiving an invite, you can notify that the call is ringing:

```js
{
	class: "collab",
	subclass: "call",
	cmd: "ringig",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8"
	},
	tid: 2000
}
```

You can optionally include an `callee` field of any type.



## accepted

After receiving an invite, you can notify that you want to answer the call:

Field|Default|Description
---|---|---|---
call_id|(mandatory)|Call ID
answer|(mandatory|Answer for the caller


**Sample**

```js
{
	class: "collab",
	subclass: "call",
	cmd: "accepted",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8",
		answer: {
			sdp: "..."
		}
	},
	tid: 2000
}
```

The server can accept or deny the answer (for example because it no longer exists or it has been already answered).


## rejected

After receiving an invite, you can notify that you want to reject the call. Then only mandatory field is `call_id`:

```js
{
	class: "collab",
	subclass: "call",
	cmd: "rejected",
	data: {
		call_id: "8b35b132-375f-b3e5-a978-28f07603cda8"
	},
	tid: 2000
}
```


## set_candidate

When the client sends an SDP _offer_ or _answer_ without candidates (and with the field `trickle_ice=true`), it must use this command to send candidates to the backend. The following fields are mandatory:

Field|Sample|Description
---|---|---
call_id|(mandatory)|Call ID this candidate refers to
sdpMid|"audio"|Media id
sdpMLineIndex|0|Line index
candidate|"candidate..."|Current candidate


## set_candidate_end

When the client has no more candidates to send, it should use this command to inform the server.



## Events


All events have the following structure:

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "collab",
		subclass: "call",
		type: "...",
		obj_id: "...",
		body: {
			...
		}
	},
	tid: 1
}
```

Then `obj_id` will be the _session id_ of the session generating the event. The following _types_ are supported:


Type|Body|Description
---|---|---
ringing|{callee=>...}|The call is ringing. Callee's info is included
accepted|{callee=>...}|The call has been accepted on this callee
hangup|{code: Code, reason: Reason}|The call has been hangup
answer|{session_id=>..., answer=>..., callee=>...}|The caller's answer is available
candidate|{sdpMid=>..., sdpMLineIndex=>..., candidate=>...}|A candidate is available


**Sample**

```js
{
	class: "core",
	cmd: "event",
	data: {
		class: "collab",
		subclass: "call",
		type: "ringing",
		obj_id: "90076c74-391a-153c-f6c7-38c9862f00d9": {
	},
	tid: 1
}
```


# Destinations

This plugins supports the following destinations:

* **user**
* **session**
* **sip**
* **verto**






