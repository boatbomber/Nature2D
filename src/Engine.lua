-- The Engine or the core of the library handles all the RigidBodies, constraints and points. 
-- It's responsible for the simulation of these elements and handling all tasks related to the library.

-- Services and utilities
local RigidBody = require(script.Parent.Physics.RigidBody)
local Point = require(script.Parent.Physics.Point)
local Constraint = require(script.Parent.Physics.Constraint)
local Globals = require(script.Parent.Constants.Globals)
local Signal = require(script.Parent.Utilities.Signal)
local Quadtree = require(script.Parent.Utilities.Quadtree)
local Types = require(script.Parent.Types)
local throwException = require(script.Parent.Debugging.Exceptions)
local throwTypeError = require(script.Parent.Debugging.TypeErrors)
local RunService = game:GetService("RunService")

local Engine = {}
Engine.__index = Engine

-- [PRIVATE]
-- This method is responsible for separating two rigidbodies if they collide with each other.
local function CollisionResponse(body: Types.RigidBody, other: Types.RigidBody, isColliding: boolean, Collision: Types.Collision, dt: number)
	if not isColliding then return end
	
	-- Fire the touched event
	body.Touched:Fire(other.id)
	
	-- Calculate penetration in 2 dimensions
	local penetration: Vector2 = Collision.axis * Collision.depth
	local p1: Types.Point = Collision.edge.point1
	local p2: Types.Point = Collision.edge.point2
	
	-- Calculate a t alpha value
	local t
	if math.abs(p1.pos.X - p2.pos.X) > math.abs(p1.pos.Y - p2.pos.Y) then
		t = (Collision.vertex.pos.X - penetration.X - p1.pos.X)/(p2.pos.X - p1.pos.X)
	else 
		t = (Collision.vertex.pos.Y - penetration.Y - p1.pos.Y)/(p2.pos.Y - p1.pos.Y)
	end
	
	-- Create a lambda
	local factor: number = 1/(t^2 + (1 - t)^2)
	
	-- If the body is not anchored, apply forces to the constraint
	if not Collision.edge.Parent.anchored then 
		p1.pos -= penetration * ((1 - t) * factor/2)
		p2.pos -= penetration * (t * factor/2)
	end
	
	-- If the body is not anchored, apply forces to the point
	if not Collision.vertex.Parent.Parent.anchored then 	
		Collision.vertex.pos += penetration/2
	end	
end

-- [PUBLIC]
-- This method is used to initialize basic configurations of the engine and allocate memory for future tasks.
function Engine.init(screengui: Instance)
	if not typeof(screengui) == "Instance" or not screengui:IsA("Instance") then 
		error("Invalid Argument #1. 'screengui' must be a ScreenGui.", 2) 
	end

	return setmetatable({
		bodies = {},
		constraints = {},
		points = {},
		connection = nil,
		gravity = Globals.engineInit.gravity,
		friction = Globals.engineInit.friction,
		airfriction = Globals.engineInit.airfriction,
		bounce = Globals.engineInit.bounce,
		timeSteps = Globals.engineInit.timeSteps,
		path = screengui,
		speed = Globals.speed,
		quadtrees = false,
		independent = true,
		canvas = {
			frame = nil,
			topLeft = Globals.engineInit.canvas.topLeft,
			size = Globals.engineInit.canvas.size
		},
		Started = Signal.new(),
		Stopped = Signal.new(),
		ObjectAdded = Signal.new(),
		ObjectRemoved = Signal.new()
	}, Engine)
end

-- This method is used to start simulating rigid bodies and constraints.
function Engine:Start()
	if not self.canvas then throwException("error", "NO_CANVAS_FOUND") end
	if #self.bodies == 0 then throwException("warn", "NO_RIGIDBODIES_FOUND") end
	
	-- Fire Engine.Started event
	self.Started:Fire()
	
	-- Create a RenderStepped connection
	local connection;
	connection = RunService.RenderStepped:Connect(function(dt)
		local tree;
		
		-- Create a quadtree and insert bodies if neccesary
		if self.quadtrees then 
			tree = Quadtree.new(self.canvas.topLeft, self.canvas.size, 4)

			for _, body in ipairs(self.bodies) do 
				tree:Insert(body)
			end			
		end
		
		-- Loop through each body
		-- Update the body
		-- Calculate the closest RigidBodies to a given body if neccesary
		for _, body in ipairs(self.bodies) do 
			body:Update(dt)

			local filtered = self.bodies

			if self.quadtrees then 
				local abs =  body.frame.AbsoluteSize
				local side = abs.X > abs.Y and abs.X or abs.Y

				local range = {
					position = body.center - Vector2.new(side * 1.5, side * 1.5),
					size = Vector2.new(side * 3, side * 3)
				}

				filtered = tree:Search(range, {})				
			end
			
			table.clear(body.Collisions.Other)
			local CollidingWith = {}
			
			-- Loop through the filtered RigidBodies
			-- Detect collisions
			-- Process collision response
			for _, other in ipairs(filtered) do 
				if body.id ~= other.id and (body.collidable and other.collidable) and not table.find(body.filtered, other.id) then
					local result = body:DetectCollision(other)
					local isColliding = result[1]
					local Collision = result[2]
					
					if isColliding then 
						body.Collisions.Body = true
						other.Collisions.Body = true
						table.insert(CollidingWith, other)
					else 
						body.Collisions.Body = false
						other.Collisions.Body = false
					end

					CollisionResponse(body, other, isColliding, Collision, dt)
				end
			end
			
			body.Collisions.Other = CollidingWith
			
			-- Render vertices of the body
			for _, vertex in ipairs(body.vertices) do
				vertex:Render()
			end

			body:Render()
		end
		
		-- Render all custom constraints
		if #self.constraints > 0 then 
			for _, constraint in ipairs(self.constraints) do 
				constraint:Constrain()
				constraint:Render()
			end			
		end
		
		-- Render all custom points
		if #self.points > 0 then 
			for _, point in ipairs(self.points) do 
				point:Update(dt)
				point:Render()
			end
		end
	end)

	self.connection = connection
end

-- This method is used to stop simulating rigid bodies and constraints.
function Engine:Stop()
	-- Fire Engine.Stopped event
	-- Disconnect all connections
	if self.connection then 
		self.Stopped:Fire()
		self.connection:Disconnect()
		self.connection = nil
	end
end

-- This method is used to create RigidBodies, Constraints and Points
function Engine:Create(object: string, properties: Types.Properties)
	-- Validate types of the object and property table
	throwTypeError("object", object, 1, "string")
	throwTypeError("properties", properties, 2, "table")
	
	-- Validate object
	if object ~= "Constraint" and object ~= "Point" and object ~= "RigidBody" then 
		throwException("error", "INVALID_OBJECT")
	end
	
	-- Validate property table
	for prop, value in pairs(properties) do 
		if not table.find(Globals.VALID_OBJECT_PROPS, prop) or not table.find(Globals[string.lower(object)].props, prop) then 
			throwException("error", "INVALID_PROPERTY")
		end
		
		if Globals.OBJECT_PROPS_TYPES[prop] and typeof(value) ~= Globals.OBJECT_PROPS_TYPES[prop] then 
			error(
				string.format(
					"[Nature2D]: Invalid Property type for %q. Expected %q got %q.", 
					prop,
					Globals.OBJECT_PROPS_TYPES[prop],
					typeof(value)
				),
				2
			)
		end
	end
	
	-- Check if must-have properties exist in the property table
	for _, prop in ipairs(Globals[string.lower(object)].must_have) do 
		if not properties[prop] then throwException("error", "MUST_HAVE_PROPERTY") end
	end
	
	local newObject
	
	-- Create the Point object
	if object == "Point" then 
		local newPoint = Point.new(properties.Position or Vector2.new(), self.canvas, self, {
			snap = properties.Snap, 
			selectable = false, 
			render = properties.Visible,
			keepInCanvas = properties.KeepInCanvas or true
		})
		
		-- Apply properties
		if properties.Radius then newPoint:SetRadius(properties.Radius)	end
		if properties.Color then newPoint:Stroke(properties.Color) end

		table.insert(self.points, newPoint)
		newObject = newPoint
	-- Create the constraint object
	elseif object == "Constraint" then 
		if not table.find(Globals.constraint.types, string.lower(properties.Type or "")) then 
			throwException("error", "INVALID_CONSTRAINT_TYPE") 
		end
		
		-- Validate restlength and thickness of the constraint
		if properties.RestLength and properties.RestLength <= 0 then throwException("error", "INVALID_CONSTRAINT_LENGTH") end
		if properties.Thickness and properties.Thickness <= 0 then throwException("error", "INVALID_CONSTRAINT_THICKNESS") end
		
		if properties.Point1 and properties.Point2 and properties.Type then 
			-- Calculate distance
			local dist = (properties.Point1.pos - properties.Point2.pos).Magnitude

			local newConstraint = Constraint.new(properties.Point1, properties.Point2, self.canvas, {
				restLength = properties.RestLength or dist, 
				render = properties.Visible, 
				thickness = properties.Thickness,
				support = true,
				TYPE = string.upper(properties.Type)
			}, self)
			
			-- Apply properties
			if properties.SpringConstant then newConstraint:SetSpringConstant(properties.SpringConstant) end
			if properties.Color then newConstraint:Stroke(properties.Color) end

			table.insert(self.constraints, newConstraint)	
			newObject = newConstraint
		end
	-- Create the RigidBody object
	elseif object == "RigidBody" then
		if properties.Object then 
			if not properties.Object:IsA("GuiObject") then error("'Object' must be a GuiObject", 2)	end

			local newBody = RigidBody.new(properties.Object, Globals.universalMass, properties.Collidable, properties.Anchored, self)
			
			--Apply properties
			if properties.LifeSpan then newBody:SetLifeSpan(properties.LifeSpan) end
			if properties.KeepInCanvas then newBody:KeepInCanvas(properties.KeepInCanvas) end
			if properties.Gravity then newBody:SetGravity(properties.Gravity) end
			if properties.Friction then newBody:SetFriction(properties.Friction) end
			if properties.AirFriction then newBody:SetAirFriction(properties.AirFriction) end

			table.insert(self.bodies, newBody)
			newObject = newBody
		end
	end	
	
	self.ObjectAdded:Fire(newObject)
	return newObject
end

-- This method is used to fetch all RigidBodies that have been created. 
-- Ones that have been destroyed, won't be fetched.
function Engine:GetBodies()
	return self.bodies
end

-- This method is used to fetch all Constraints that have been created. 
-- Ones that have been destroyed, won't be fetched.
function Engine:GetConstraints()
	return self.constraints
end

-- This method is used to fetch all Points that have been created. 
function Engine:GetPoints()
	return self.points
end

-- This function is used to initialize boundaries to which all bodies and constraints obey.
-- An object cannot go past this boundary.
function Engine:CreateCanvas(topLeft: Vector2, size: Vector2, frame: Frame)
	throwTypeError("topLeft", topLeft, 1, "Vector2")
	throwTypeError("size", size, 2, "Vector2")

	self.canvas.absolute = topLeft
	self.canvas.size = size

	if frame and frame:IsA("Frame") then 
		self.canvas.frame = frame
	end
end

-- This method is used to determine the simulation speed of the engine. 
-- By default the simulation speed is set to 55.
function Engine:SetSimulationSpeed(speed: number)
	throwTypeError("speed", speed, 1, "number")
	self.speed = speed
end

-- This method is used to configure universal physical properties possessed by all rigid bodies and constraints. 
function Engine:SetPhysicalProperty(property: string, value: Vector2 | number)
	throwTypeError("property", property, 1, "string")

	local properties = Globals.properties
	
	-- Update properties of the Engine
	local function Update(object)
		if string.lower(property) == "collisionmultiplier" then 
			throwTypeError("value", value, 2, "number")
			object.bounce = value
		elseif string.lower(property) == "gravity" then 
			throwTypeError("value", value, 2, "Vector2")
			object.gravity = value
		elseif string.lower(property) == "friction" then 					
			throwTypeError("value", value, 2, "number")
			object.friction = math.clamp(1 - value, 0, 1)
		elseif string.lower(property) == "airfriction" then 
			throwTypeError("value", value, 2, "number")
			object.airfriction = math.clamp(1 - value, 0, 1)
		end
	end
	
	-- Validate and update properties
	if table.find(properties, string.lower(property)) then 
		if #self.bodies < 1 then 
			Update(self)
		else 
			Update(self)
			for _, b in ipairs(self.bodies) do 
				for _, v in ipairs(b:GetVertices()) do 
					Update(v)
				end
			end
		end
	else
		throwException("error", "PROPERTY_NOT_FOUND")
	end
end

-- This method is used to fetch an individual rigid body from its ID.
function Engine:GetBodyById(id: string)
	throwTypeError("id", id, 1, "string")

	for _, b in ipairs(self.bodies) do 
		if b.id == id then 
			return b
		end
	end

	return
end

-- This method is used to fetch an individual constraint body from its ID. 
function Engine:GetConstraintById(id: string)
	throwTypeError("id", id, 1, "string")

	for _, c in ipairs(self.constraints) do 
		if c.id == id then 
			return c
		end
	end

	return 
end

-- Returns current canvas the engine adheres to.
function Engine:GetCurrentCanvas() : Types.Canvas
	return self.canvas
end

-- Determines if Quadtrees will be used in collision detection.
-- By default this is set to false
function Engine:UseQuadtrees(use: boolean)
	throwTypeError("useQuadtrees", use, 1, "boolean")
	self.quadtrees = use
end

-- Determines if Frame rate does not affect the simulation speed. 
-- By default set to true.
function Engine:FrameRateIndependent(independent: boolean)
	throwTypeError("independent", independent, 1, "boolean")
	self.independent = independent
end

return Engine