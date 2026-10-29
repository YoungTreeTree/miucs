---@meta
-- Editor-only Lua language-server definitions. Do not require this file at runtime.

---@class MiucsViewport
---@field id string Output node id declared in manifest.visualizations
---@field width number Logical viewport width
---@field height number Logical viewport height
---@field scale number Backing pixels per logical viewport unit

---@class MiucsAppearance
---@field ink string #RRGGBB
---@field opacity? number 0..1; Mac host also applies window opacity

---@class MiucsKeyboardEvent
---@field sequence integer Only compare inside one sessionID
---@field receivedAt number Host-monotonic seconds
---@field kind 'pressed'|'repeated'|'released'|'modifiersChanged'
---@field key? string Physical identity; nil for an unsupported physical key
---@field modifiers integer Shared KeyboardModifiers bitmask
---@field heldDuration? number
---@field modifierIsPressed? boolean

---@class MiucsKeyboard
---@field version integer
---@field sessionID string
---@field sequence integer
---@field sampledAt number Host-monotonic seconds
---@field state string Existing keyboard contract state
---@field modifiers integer
---@field pressesPerSecond number
---@field idleDuration? number
---@field droppedEventCount integer Unread events lost since the prior read
---@field events MiucsKeyboardEvent[]
---@field heldKeys {key: string?, duration: number}[]

---@class MiucsAudio
---@field version integer
---@field sessionID string
---@field state string Existing audio contract state
---@field frame? table See ../audio-features/frame.schema.json; never raw PCM
---@field frameAge? number Host-monotonic age in seconds
---@field onsets table[] At most 64 events, 250 ms TTL
---@field beats table[] At most 64 events, 250 ms TTL
---@field spectralFluxPeak number
---@field droppedOnsetCount? integer Events discarded by the worker queue
---@field droppedBeatCount? integer Events discarded by the worker queue

---@class MiucsFrame
---@field now number Host-monotonic seconds; do not subtract audio.time
---@field deltaTime number Actual elapsed seconds, possibly coalesced
---@field audio? MiucsAudio Present only when declared in inputs
---@field keyboard? MiucsKeyboard Present only when declared in inputs

---@class MiucsNode
---@field type 'group'|'path'|'image'|'text'|'rect'|'ellipse'
---@field id string Unique within the package, stable across frames
---@field children? MiucsNode[] Creation only
---@field x? number
---@field y? number
---@field width? number
---@field height? number
---@field rotation? number Radians, clockwise in y-down coordinates
---@field scaleX? number
---@field scaleY? number
---@field matrix? number[] Optional affine a,b,c,d,tx,ty, replacing rotation/scale
---@field pivot? number[] Normalized fractions of width and height
---@field opacity? number
---@field visible? boolean
---@field z? number Defaults to zero; ties use scene declaration order
---@field fill? string #RRGGBB or #RRGGBBAA
---@field stroke? string Stroke replaces fill; use separate nodes for both
---@field strokeWidth? number Local units
---@field constantStroke? boolean Compensates this node's scaleX
---@field haloWidth? number
---@field haloOpacity? number
---@field halo? boolean Built-in white outline behind stroked paths
---@field antialias? boolean
---@field pathRef? string Shared geometry handle: ID of a concrete path node
---@field path? table[] Commands: {"M",x,y}, {"L",x,y}, {"Q",cx,cy,x,y}, {"C",c1x,c1y,c2x,c2y,x,y}, {"Z"}
---@field source? string Confined relative image path
---@field sourceRect? number[] Atlas pixels: x,y,width,height
---@field sampling? 'nearest'|'linear'
---@field font? string Confined relative TTF/OTF path
---@field fontSize? number
---@field baseline? number Text baseline relative to node y
---@field text? string UTF-8, simple glyph drawing (no complex-script shaping)
---@field radius? number Rounded rect corner radius
---@field clip? number[] Local x,y,width,height
---@field gradient? table Linear gradient: from={x,y}, to={x,y}, stops={{t,"#RRGGBBAA"},...}
---@field mask? table Same gradient structure, applied with destination-in alpha

---@class MiucsLifecycle
---@field create? fun(context: {api: integer, seed: integer})
---@field activate? fun(viewport: MiucsViewport)
---@field update? fun(frame: MiucsFrame)
---@field resize? fun(viewport: MiucsViewport)
---@field appearanceChanged? fun(appearance: MiucsAppearance)
---@field deactivate? fun()
---@field dispose? fun() Must tolerate repeated disposal

miucs = {}
---@param root MiucsNode
function miucs.load(root) end
---@param id string
---@param properties table Only changed fields; identity/hierarchy cannot be changed
function miucs.set(id, properties) end
---@return number value Deterministic value in [0,1); per-worker default seed 1
function miucs.random() end
---@param relativePath string Lua source path within this package; loaded once per worker
---@return any module
function miucs.require(relativePath) end
