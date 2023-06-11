local CollectionService = game:GetService("CollectionService")

local Observers = require(script.Parent.Observers)
local TableUtil = require(script.Parent.TableUtil)
local Signal = require(script.Parent.Signal)
local Trove = require(script.Parent.Trove)
local Promise = require(script.Parent.Promise)

local observeTag = Observers.observeTag

local ComponentBinder = {}
ComponentBinder.__index = ComponentBinder

type AnyTable = { [any]: any }

type Destroyable = {
    Destroy: () -> ()
}

type BindableClass = {
    new: (instance: Instance, context: AnyTable?) -> Destroyable
}

type ComponentBinderProps = {
    Tag: string,
    Class: BindableClass,
    Ancestors: { Instance }?,
    Context: AnyTable?
}

function ComponentBinder.new(componentBinderProps)
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

function ComponentBinder:Get(instance)
    return self._objects[instance]
end

function ComponentBinder:WaitFor(instance)
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

function ComponentBinder:Bind(instance)
    CollectionService:AddTag(instance, self._tag)
    return self:Get(instance)
end

function ComponentBinder:BindAsync(instance)
    CollectionService:AddTag(instance, self._tag)
    return self:WaitFor(instance)
end

function ComponentBinder:GetAll()
    return TableUtil.Values(self._objects)
end

function ComponentBinder:ObserveObjects(callback)
    local cleanups = {}

    for _, object in self._objects do
        cleanups[object] = callback(object)
    end

    local addedSignal = self:GetObjectAddedSignal()
    local removingSignal = self:GetObjectRemovingSignal()

    local addedConnection = addedSignal:Connect(function(object)
        cleanups[object] = callback(object)
    end)

    local removingConnection = removingSignal:Connect(function(object)
        local cleanup = cleanups[object]

        if cleanup then
            cleanup()
            cleanups[object] = nil
        end
    end)

    return function()
        addedConnection:Disconnect()
        removingConnection:Disconnect()

        for _, cleanup in cleanups do
            cleanup()
        end
    end
end

function ComponentBinder:_bind(instance)
    local object = self._class.new(instance, self._context)
    self._objects[instance] = object
end

function ComponentBinder:_unbind(instance)
    local object = self._objects[instance]

    if object then
        object:Destroy()
        self._objects[instance] = nil
    end
end

function ComponentBinder:Start()
    local stopObserver = observeTag(self._tag, function(instance)
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