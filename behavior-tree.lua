local lib = {}


-- Classic Mini

--- @class BehaviorTree.Class : table
--- @field private __index table
--- @field protected super table
local class = {}
class.__index = class


function class:init( ... ) end


--- @protected
function class:extend()
    local newClass = {}

    for key, value in pairs( self ) do
        if string.find( key, "__" ) ~= 1 then goto skip end

        newClass[ key ] = value

        ::skip::
    end

    newClass.__index = newClass
    newClass.super = self

    return setmetatable( newClass, self )
end


--- @private
function class:__call( ... )
    local object = setmetatable( {}, self )
    object:init( ... )
    return object
end


-- Result Enum

--- @enum BehaviorTree.Result
local resultEnum = {
    RUNNING = "RUNNING",
    SUCCESS = "SUCCESS",
    FAILURE = "FAILURE"
}


lib.result = resultEnum


-- === Base Node ===

--- @class BehaviorTree.Node : BehaviorTree.Class
--- @field protected initialized boolean
--- @field protected root table
--- @field protected interface table
local node = class:extend()


--- @private
function node:init()
    self.initialized = false
    self.interface = self
end


--- @protected
--- @return BehaviorTree.Result
function node:tick()
    if self.initialized == false then
        self.initNode( self.interface )
        self.initialized = true
    end

    local result = self.doRun( self.interface )

    if result == resultEnum.RUNNING then return result end

    self.initialized = false

    return result
end


--- @private
function node:initNode() end
--- @private
--- @return BehaviorTree.Result
function node:doRun() assert( false ) return resultEnum.FAILURE end


-- === Root ===

--- @class BehaviorTree.Root : BehaviorTree.Class
--- @field private rootNode BehaviorTree.Node
--- @field private rootData table # this is for when the root is the top of the tree
--- @field private root table # this is for when the root is embedded in another tree
local root = class:extend()


--- @private
function root:init( rootNode )
    self.rootNode = rootNode
    self.rootData = {}
end


--- @private # this is for when the root is embedded in another tree
function root:tick()
    self.rootNode.root = self.root -- passes the root it got from its parent node to the tree
    return self.rootNode:tick()
end


--- @public # this is for when the root is the top of the tree
--- @return BehaviorTree.Result
function root:run()
    self.rootNode.root = self.rootData -- passes its own table to the tree
    return self.rootNode:tick()
end


--- Works because the constructor is in a __call metafunction

--- @type fun( rootNode : BehaviorTree.Node ) : BehaviorTree.Root
--- @diagnostic disable-next-line
lib.root = root


-- === Leaf ===

--- @class BehaviorTree.Leaf : BehaviorTree.Node
--- @field private interface table
--- @field private doRun function
--- @field private initNode function
local leaf = node:extend()


--- @private
function leaf:init( run, init )
    self.super.init( self )
    self.doRun = run

    self.interface = setmetatable( {}, {
        __index = function ( _, key ) return self.root[ key ] end,
        __newindex = function ( _, key, value ) self.root[ key ] = value end
    } )

    if init == nil then return end

    self.initNode = init
end


--- Works because the constructor is in a __call metafunction

--- @type fun( run : fun( tree : table ) : BehaviorTree.Result, init : fun( tree )? ) : BehaviorTree.Leaf
--- @diagnostic disable-next-line
lib.leaf = leaf


-- === Decorator ===

--- @class BehaviorTree.Decorator : BehaviorTree.Node
--- @field child BehaviorTree.Node
local decorator = node:extend()


--- @private
function decorator:init( child )
    decorator.super.init( self )
    self.child = child
end


function decorator:tickChild()
    self.child.root = self.root
    return self.child:tick()
end


-- Inverter

--- @class BehaviorTree.Inverter : BehaviorTree.Decorator
local inverter = decorator:extend()


--- @private
function inverter:doRun()
    local result = self:tickChild()

    if result == resultEnum.RUNNING then return result end
    if result == resultEnum.FAILURE then return resultEnum.SUCCESS end
    if result == resultEnum.SUCCESS then return resultEnum.FAILURE end
end


--- Works because the constructor is in a __call metafunction

--- @type fun( child : BehaviorTree.Node ) : BehaviorTree.Inverter
--- @diagnostic disable-next-line: assign-type-mismatch
lib.inverter = inverter


-- Succeeder

--- @class BehaviorTree.Succeeder : BehaviorTree.Decorator
local succeeder = decorator:extend()


function succeeder:doRun()
    local result = self:tickChild()

    if result == resultEnum.RUNNING then return result end
    return resultEnum.SUCCESS
end


--- Works because the constructor is in a __call metafunction

--- @type fun( child : BehaviorTree.Node ) : BehaviorTree.Succeeder
--- @diagnostic disable-next-line: assign-type-mismatch
lib.succeeder = succeeder


-- Repeater

--- @class BehaviorTree.Repeater : BehaviorTree.Decorator
--- @field private numberOfTimes integer
--- @field private count integer
local repeater = decorator:extend()


function repeater:init( child, numberOfTimes )
    repeater.super.init( self, child )
    self.numberOfTimes = numberOfTimes
end


function repeater:initNode()
    self.count = 0
end


function repeater:doRun()
    local result = self:tickChild()

    if result == resultEnum.RUNNING then return result end

    if self.numberOfTimes ~= nil then
        self.count = self.count + 1

        if self.count >= self.numberOfTimes then return result end
    end

    return resultEnum.RUNNING
end


--- Works because the constructor is in a __call metafunction

--- @type fun( child : BehaviorTree.Node, numberOfTimes : integer? ) : BehaviorTree.Repeater
--- @diagnostic disable-next-line
lib.repeater = repeater


-- Repeat Until Fail

--- @class BehaviorTree.RepeatUntilFail : BehaviorTree.Decorator
local repeatUntilFail = decorator:extend()


function repeatUntilFail:doRun()
    local result = self:tickChild()

    if result == resultEnum.FAILURE then return resultEnum.SUCCESS end

    return resultEnum.RUNNING
end


--- Works because the constructor is in a __call metafunction

--- @type fun( child : BehaviorTree.Node ) : BehaviorTree.RepeatUntilFail
--- @diagnostic disable-next-line
lib.repeatUntilFail = repeatUntilFail


-- === Composite ===

--- @class BehaviorTree.Composite : BehaviorTree.Node
--- @field protected children BehaviorTree.Node[]
--- @field protected iterator thread
--- @field protected child BehaviorTree.Node
local composite = node:extend()


--- @private
function composite:init( ... )
    composite.super.init( self )
    self.children = { ... }
end


--- @private
function composite:makeIterator()
    self.iterator = coroutine.create( function ()
        for _, child in ipairs( self.children ) do coroutine.yield( child ) end
    end )
end


--- @protected
function composite:nextChild()
    if coroutine.status( self.iterator ) == "dead" then
        self:makeIterator()
    end

    local _, child = coroutine.resume( self.iterator )
    self.child = child

    if child == nil then return end

    child.root = self.root
end


--- @private
function composite:initNode()
    self:makeIterator()
    self:nextChild()
end


-- Sequence

--- @class BehaviorTree.Sequence : BehaviorTree.Composite
local sequence = composite:extend()


--- @private
function sequence:doRun()
    local result = self.child:tick()

    if result == resultEnum.RUNNING then return result end

    if result == resultEnum.FAILURE then return result end

    if result == resultEnum.SUCCESS then
        self:nextChild()

        if self.child == nil then return result end

        return resultEnum.RUNNING
    end
end


--- Works because the constructor is in a __call metafunction

--- @type fun( ... : BehaviorTree.Node ) : BehaviorTree.Sequence
--- @diagnostic disable-next-line
lib.sequence = sequence


-- Selector

--- @class BehaviorTree.Selector : BehaviorTree.Composite
local selector = composite:extend()


--- @private
function selector:doRun()
    local result = self.child:tick()

    if result == resultEnum.RUNNING then return result end

    if result == resultEnum.SUCCESS then return result end

    if result == resultEnum.FAILURE then
        self:nextChild()

        if self.child == nil then return result end

        return resultEnum.RUNNING
    end
end


--- Works because the constructor is in a __call metafunction

--- @type fun( ... : BehaviorTree.Node ) : BehaviorTree.Selector
--- @diagnostic disable-next-line
lib.selector = selector


return lib