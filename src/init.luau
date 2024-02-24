local CollectionService = game:GetService("CollectionService")

local Observers = require(script.Parent.Observers)
local Observe = require(script.Parent.Observe)
local TableUtil = require(script.Parent.TableUtil)
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Trove)
local Promise = require(script.Parent.Promise)

local observeTag = Observers.observeTag

local ComponentBinder = {}
ComponentBinder.__index = ComponentBinder

type AnyTable = { [any]: any }

type Destroyable = {
    Destroy: () -> (),
    [any]: any,
}

type Cleanup = () -> ()
type Handler<T...> = ((T...) -> Cleanup) | ((T...) -> ())

type BindableClass = {
    new: (instance: Instance, context: AnyTable?) -> Destroyable,
    [any]: any,
}

type ComponentBinderProps<T> = {
    Tag: string,
    Class: T & BindableClass,
    Ancestors: { Instance }?,
    Context: AnyTable?
}

type Signal<T...> = Signal.Signal<T...>

-- This is the best I can do for now
type Promise<T...> = {
    await: (self: Promise<T...>) -> (boolean, T...),
    expect: (self: Promise<T...>, message: string) -> T...,

    andThen: (self: Promise<T...>, callback: (T...) -> any) -> any,
    catch: (self: Promise<T...>, callback: (string) -> any) -> Promise<T...>,

    finally: (self: Promise<T...>, callback: () -> any) -> Promise<T...>,

    [string]: any,
}

export type ComponentBinder<T> = {
    GetObjectAddedSignal: (self: ComponentBinder<T>) -> Signal<T>,
    GetObjectRemovingSignal: (self: ComponentBinder<T>) -> Signal<T>,
    Get: (self: ComponentBinder<T>, instance: Instance) -> T?,
    WaitFor: (self: ComponentBinder<T>, instance: Instance) -> Promise<T>,
    Bind: (self: ComponentBinder<T>, instance: Instance) -> T?,
    BindAsync: (self: ComponentBinder<T>, instance: Instance) -> Promise<T>,
    GetAll: (self: ComponentBinder<T>) -> { T },
    ObserveObjects: (self: ComponentBinder<T>, handler: Handler<T>) -> Cleanup,
    Start: (self: ComponentBinder<T>) -> (),
    Destroy: (self: ComponentBinder<T>) -> (),
}

function ComponentBinder.new<T>(componentBinderProps: ComponentBinderProps<T>): ComponentBinder<T>
    local self = setmetatable({}, ComponentBinder)
    
    self._trove = Trove.new()

    self._tag = componentBinderProps.Tag
    self._class = componentBinderProps.Class
    self._ancestors = componentBinderProps.Ancestors
    self._context = componentBinderProps.Context

    self._objectAddedSignal = nil
    self._objectRemovingSignal = nil

    self._objects = {}

    return self
end

function ComponentBinder:GetObjectAddedSignal()
    if not self._objectAddedSignal then
        self._objectAddedSignal = self._trove:Construct(Signal)
    end

    return self._objectAddedSignal
end

function ComponentBinder:GetObjectRemovingSignal()
    if not self._objectRemovingSignal then
        self._objectRemovingSignal = self._trove:Construct(Signal)
    end

    return self._objectRemovingSignal
end

function ComponentBinder:Get(instance: Instance)
    return self._objects[instance]
end

function ComponentBinder:WaitFor(instance: Instance)
    if self._objects[instance] then
        return Promise.resolve(self._objects[instance])
    end

    return Promise.new(function(resolve, reject, onCancel)
        local connection = nil

        connection = self:GetObjectAddedSignal():Connect(function(object)
            if object == instance then
                connection:Disconnect()
                resolve(object)
            end
        end)

        onCancel(function()
            connection:Disconnect()
        end)
    end)
end

function ComponentBinder:Bind(instance: Instance)
    CollectionService:AddTag(instance, self._tag)
    return self:Get(instance)
end

function ComponentBinder:BindAsync(instance: Instance)
    CollectionService:AddTag(instance, self._tag)
    return self:WaitFor(instance)
end

function ComponentBinder:GetAll()
    return TableUtil.Values(self._objects)
end

function ComponentBinder:ObserveObjects<T>(handler: Handler<T>)
    return Observe.AddedRemovedSignal(self:GetAll(), self:GetObjectAddedSignal(), self:GetObjectRemovingSignal(), handler)
end

function ComponentBinder:_bind(instance: Instance)
    local object = self._class.new(instance, self._context)
    self._objects[instance] = object

    if self._objectAddedSignal then
        self._objectAddedSignal:Fire(object)
    end
end

function ComponentBinder:_unbind(instance: Instance)
    local object = self._objects[instance]

    if not object then
        return
    end

    if self._objectRemovingSignal then
        self._objectRemovingSignal:Fire(object)
    end

    object:Destroy()
    self._objects[instance] = nil
end

function ComponentBinder:Start()
    local stopObserver = observeTag(self._tag, function(instance: Instance)
        self:_bind(instance)

        return function()
            self:_unbind(instance)
        end
    end, self._ancestors)

    self._trove:Add(stopObserver)
end

function ComponentBinder:Destroy()
    self._trove:Clean()
end

return ComponentBinder