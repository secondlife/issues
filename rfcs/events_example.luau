--!nonstrict

-- Proposal for Event handling and Timer handling APIs, to be implemented in native code upon approval
-- Status: proposed

-- Event handlers which stack multiple events together in LSL via an integer `num_detected` parameter
-- TODO: Pass in a special wrapper object for these functions and loop through `num_detected` rather
--       than actually pass in `num_detected`? Seems like almost nobody uses these functions as
--       intended since it's annoying to have to write the loop, everyone just does `llDetectedWhatever(0)`
--       and silently drops the rest of the queued events of that type on the floor.
local _MULTI_EVENT_NAMES = {
    "touch_start",
    "touch_end",
    "touch", 
    "collision_start", 
    "collision", 
    "collision_end",
    "sensor",
    "damage",
    "final_damage",
}

type EventHandler = (...any) -> ()

type LLEventsProto = {
    -- Event name -> array of handler functions
    _handlers: { [string]: { EventHandler } },

    -- Dynamic event handler management
    -- Returns the registered handler so it can be unregistered later, if an anonymous function.
    on: (self: LLEventsProto, event_name: string, handler: EventHandler) -> EventHandler,
    once: (self: LLEventsProto, event_name: string, handler: EventHandler) -> EventHandler,
    off: (self: LLEventsProto, event_name: string, handler: EventHandler?) -> boolean,
    listeners: (self: LLEventsProto, event_name: string) -> { EventHandler },
    eventNames: (self: LLEventsProto) -> { string },

    -- Internal methods, not part of the public API
    _handle_event: (self: LLEventsProto, name: string, ...any) -> (),
    _create_event_catcher: (self: LLEventsProto, name: string) -> EventHandler,
}

local DetectedEvent = {}
DetectedEvent.__index = DetectedEvent

-- I'm lazy, but assume this was something sensible
type DetectedEvent = any

-- These won't actually be a table in prod, but a userdata that holds an integer and two booleans.
-- Relatively low-overhead.
function DetectedEvent:new(index: number, canAdjustDamage: boolean): DetectedEvent
    return setmetatable({
        index=index,
        valid=true,
        canAdjustDamage=canAdjustDamage,
    }, self)
end

function DetectedEvent:adjustDamage(damage: number)
    assert(self.valid and self.canAdjustDamage)
    ll.AdjustDamage(self.index, damage)
end

local function _makeWrapper(detected_name)
    local underlyingFunc = ll['Detected' .. detected_name]
    return function(obj: DetectedEvent)
        if not obj.valid then
            error(`{obj} is not valid anymore`)
        end
        return underlyingFunc(obj.index)
    end
end

local DETECTED_TYPES = {
    'Owner',
    'Name',
    'Face',
    'LinkNumber',
    'Key',
    -- Etc.
}

-- Slap the wrapper methods onto `DetectedEvent`
for i, v in DETECTED_TYPES do
    DetectedEvent['get' .. v] = _makeWrapper(v)
end


local LLEvents = {_handlers = {}} :: LLEventsProto

-- Add a dynamic event handler
function LLEvents:on(event_name: string, handler: EventHandler): EventHandler
    -- TODO: Make this error() when an unrecognized event name is used
    local existing_handlers = self._handlers[event_name] or {}
    table.insert(existing_handlers, handler)
    self._handlers[event_name] = existing_handlers
    -- Note: this is where object touchability and such would be updated by the sim
    -- if there were no handlers before
    return handler
end

-- Remove event handler(s)
function LLEvents:off(event_name: string, handler: EventHandler?): boolean
    -- TODO: Make this error() when an unrecognized event name is used

    -- We used to support a `nil` handler as an indication to unregister _all_ handlers
    -- of a given type, but this lead to subtle bugs when the passed in handler
    -- was expected to be non-nil and in fact was.
    -- All events or handlers for events may be unsubscribed by looping over
    -- `eventNames()` and `listeners()`, respectively.
    assert(handler ~= nil)

    local handlers = self._handlers[event_name]
    if not handlers then
        -- Nothing to unsubscribe
        return false
    end

    -- Find the handler first, then remove it
    local found_index = nil        
    for i=#handlers,1,-1 do
        if handlers[i] == handler then
            found_index = i
            break  -- Find the last match, then stop
        end
    end

    if not found_index then
        return false
    end

    table.remove(handlers, found_index)

    -- Clean up empty handler arrays
    if #handlers == 0 then
        self._handlers[event_name] = nil
        -- Note: this is where object touchability and such would be updated by the sim
        -- if there were no handlers left
    end
    return true
end

-- Add a one-time event handler
function LLEvents:once(event_name: string, handler: EventHandler): EventHandler
    local function wrapper(...: any)
        -- Remove the wrapper BEFORE calling the handler to avoid issues if handler errors
        -- TODO: How would calling `:off(event_name, handler)` work before this triggers?
        --       Should it work at all? Technically we registered `wrapper` and not `handler`.
        self:off(event_name, wrapper)
        handler(...)
    end
    return self:on(event_name, wrapper)
end

-- Return all events that have active listeners
function LLEvents:listeners(event_name: string): {EventHandler}
    local handlers = self._handlers[event_name]
    if not handlers then
        return {}
    end
    return table.clone(handlers)
end

-- Get names of all registered events
function LLEvents:eventNames(): {string}
    local names = {}
    for k, v in self._handlers do
        table.insert(names, k)
    end
    return names
end

-- Call dynamic handlers for these events
function LLEvents:_handle_event(name: string, ...: any): ()
    local handlers = table.clone(self._handlers[name] or {})
    local event_args = ...

    local event_wrappers = {}
    if table.find(_MULTI_EVENT_NAMES, name) then
        -- Create `DetectedEvent` wrappers
        local num_detected = event_args
        for i=1,num_detected do
            -- These are 0-indexed for now.
            table.insert(event_wrappers, DetectedEvent:new(i - 1, name == 'damage'))
        end
        -- Replace the event args with our table of event wrappers
        event_args = event_wrappers
    end

    -- Do the actual event handling
    for i, handler in handlers do
        -- We explicitly want errors to bubble up to the global error handler, no pcall().
        handler(event_args)
    end

    -- Now clean up and mark those wrappers invalid so people know not to use them anymore
    for i, wrapper in event_wrappers do
        wrapper.valid = false
    end
end

-- Bridge the gap between the existing events system and our new one
function LLEvents:_create_event_catcher(name: string): EventHandler
    local function catcher(...: any)
        self:_handle_event(name, ...)
    end
    return catcher
end

-- Metatable to support function `function LLEvents.event_name(...) ... end` syntax
local _LLEventsMeta = {
    __newindex = function(self, key: string, value: any)
        if type(value) == "function" then
            -- Setting a function - treat as event handler registration
            self:on(key, value)
        else
            -- Setting non-function - use normal assignment
            rawset(self, key, value)
        end
    end,

    __index = function(self, key: string): any
        -- First check if it's a method or property on the LLEvents
        local raw_value = rawget(self, key)
        if raw_value ~= nil then
            return raw_value
        end
        
        -- No magic for _getting_ event handlers via the metatable, just return nil.
        return nil
    end,
}

LLEvents = setmetatable(LLEvents, _LLEventsMeta)




-- Timer code starts here
type _LLTimerData = {
    handler: EventHandler,
    -- Absolute timestamp of when to run next.
    -- Note that when actually implemented this will be serialized with the object as
    --  an _`os.clock()`-relative_ time to keep existing timer event semantics.
    nextRun: number,
    -- How long to wait in between invocations of this timer
    interval: number?,
}

type LLTimersProto = {
    -- TODO: Only use llSetTimerEvent for scheduling intervals. Since llSetTimerEvent accuracy
    --       drops after 4.5 hours, make sure this gets run once every 4 hours or so with some slop,
    --       even if we don't need to do anything, as long as there's a scheduled timer active.
    -- NOTE: timers are not in wallclock time, they are in rezzed-time, they do not tick while
    --       objects are de-rezzed!
    on: (self: LLTimersProto, seconds: number, handler: EventHandler) -> EventHandler,
    once: (self: LLTimersProto, seconds: number, handler: EventHandler) -> EventHandler,
    off: (self: LLTimersProto, handler: EventHandler?) -> boolean,

    -- Internal API
    _tick: (self: LLTimersProto) -> (),
    _scheduleNextTick: (self: LLTimersProto) -> (),

    _timers: {_LLTimerData},
}



local LLTimers = {_timers = {}} :: LLTimersProto

-- Do the actual running of the timers
function LLTimers:_tick()
    local start_time = os.clock()

    -- So we don't get affected by subscriptions that happen
    local timers: {_LLTimerData} = table.clone(self._timers)
    -- Iterate in reverse for similar reasons
    for i=#self._timers,1,-1 do
        local handler_data = timers[i]
        -- Make sure this still exists in the base _timers before we try and run it,
        -- something might have unscheduled it while we were iterating.
        local handler_idx = table.find(self._timers, handler_data)
        if not handler_idx then
            continue
        end

        -- Not time to run this yet
        if handler_data.nextRun > start_time then
            continue
        end
    
        if handler_data.interval == nil then
            -- One-shot timer, immediately unschedule it
            table.remove(self._timers, handler_idx)
        else
            -- Schedule its next run
            -- It's fine to do this even if something has already removed it from
            -- self._timers elsewhere, this won't revive it.
            handler_data.nextRun = start_time + handler_data.interval
        end

        -- Actually call the handler now
        -- No pcall(), errors bubble up to the global error handler!
        handler_data.handler()
    end

    self:_scheduleNextTick()
end

function LLTimers:_scheduleNextTick()
    if not #self._timers then
        -- No timers pending, unsubscribe from the parent timer event.
        ll.SetTimerEvent(0.0)
        return
    end

    -- Figure out when we next need to wake up to handle events
    local min_time = math.huge
    for k, v in self._timers do
        min_time = math.min(v.nextRun, min_time)
    end

    -- We still have events to run, makes sure we have a positive, non-zero interval.
    -- Timer events are relative, but our stored times are absolute!
    local next_interval = math.max(0.000001, min_time - os.clock())
    ll.SetTimerEvent(next_interval)
end

function LLTimers:on(seconds: number, handler: EventHandler): EventHandler
    assert(seconds > 0)
    table.insert(self._timers, {
        nextRun=os.clock() + seconds,
        interval=seconds,
        handler=handler,
    } :: _LLTimerData)
    self:_scheduleNextTick()
    return handler
end

function LLTimers:once(seconds: number, handler: EventHandler): EventHandler
    assert(seconds > 0)
    table.insert(self._timers, {
        nextRun=os.clock() + seconds,
        interval=nil,
        handler=handler,
    } :: _LLTimerData)
    self:_scheduleNextTick()
    return handler
end

function LLTimers:off(handler: EventHandler): boolean
    local found_index = false
    for i=#self._timers,1,-1 do
        if self._timers[i].handler == handler then
            table.remove(self._timers, i)
            found_index = true
            break
        end
    end
    self:_scheduleNextTick()
    return found_index
end



-- this won't be in actual code you write, this is just to wire up the example code to how events are currently handled
touch_start = LLEvents:_create_event_catcher("touch_start")
collision_start = LLEvents:_create_event_catcher("collision_start")
function timer()
    LLTimers:_tick()
end



-- Example user code starts here


-- Example using the convenient assignment syntax
-- This is equivalent to:
-- LLEvents:on("collision_start", function(evts) ... end)
function LLEvents.collision_start(evts: {DetectedEvent})
    -- Loop over the events
    for _, evt in evts do
        print(`[Assignment Handler] Collision detected {evt:getKey()}`)
    end
end


local function main()
    -- Example: Add a handler that logs all touch events
    LLEvents:on("touch_start", function(evts: {DetectedEvent})
        print(`[Global] I was touched by {evts[1]:getName()}`)
    end)

    -- Example: Add another handler that can be removed later
    local counter = 0
    local function count_handler()
        counter += 1
        print(`[Counter] Touch count: {counter}`)

        -- Remove this handler after 5 touches
        if counter >= 5 then
            LLEvents:off("touch_start", count_handler)
            print("[Counter] Counter handler removed after 5 touches")
        end
    end
    LLEvents:on("touch_start", count_handler)

    -- Now do some timer tests
    local tick_count = 0
    LLTimers:on(10, function()
        tick_count += 1
        print(`[Tick Counter] tick count {tick_count}`)
    end)

    local start_time = os.clock()
    -- This only runs once!
    LLTimers:once(22, function()
        print(`[Tick Once] I ran {os.clock() - start_time} seconds after starting`)
    end)

    local cancellable_runs = 0
    local function cancellable()
        cancellable_runs += 1
        print(`[Tick Cancellable] I've run {cancellable_runs} times`)
        if cancellable_runs >= 2 then
            -- We only run twice, cancel after the second run.
            LLTimers:off(cancellable)
        end
    end
    LLTimers:on(2, cancellable)
end

main()
