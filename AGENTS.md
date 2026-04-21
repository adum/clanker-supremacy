# AGENTS.md

We are building a Factorio mod. The idea is to create an enemy-builder entity that goes and builds their own little base and eventually uses it to attack the player. It's a different kind of enemy than the standard biter.

There are some basic principles that we're going to follow here in terms of how the high level logic should work
1. The builder has to be very reliable. That means not getting stuck. Even if something isn't working, or even if an opponent actively destroys some critical infrastructure. It's okay to be set back and have plans ruined, but it must keep moving forward and not just sit in a broken state.
2. It's okay for the builder to be a little bit janky, and in fact this is preferable. You can build some spaghetti bases. It can make a lot of things that aren't very efficient. It can use weird tech choices, all that.
3. It should ramp up in difficulty over time and in its abilities, but it doesn't necessarily use the same tech tree or even do any research. It might even use unique items that have pros and cons compared to the player.
4. It will basically start out by building a little base and scaling up, but then at some point it has to do something to go seek out the player and provide an active opponent. Otherwise, somebody could just ignore it if they're building their own base.
5. It's fine for it to build things that don't quite work and then just abandon them. It doesn't need to be efficient with resources, because in Factorio resources are effectively infinite.
6. We're going to build long strings of transport belts. We can split off them, and use underground when necessary.

Code and architecture wise:
- This is going to get pretty complicated, so it's important to have good, clean architecture and test cases.
- We also need great debugging tools and visualizations and ways to see what the builder is doing.
- The key is to code SIMPLE and fast algorithms. It's okay for them to not be precise. For example, the builder might start making a project that combines a bunch of assemblers and inserters for a final project. Then before it gets to the end, he runs out of room due to a cliff. That's fine. He can just abandon that effort and try again later. This is much better than trying to calculate the needed space up front and worrying about the cliffs.
- Don't add extra code to support old save files if we update something. It's totally fine to not be backwards compatible. It's much better to have simpler code that only works going forward. 
- We have to do things quickly. Any long running functions cause hangs in the UI. Everything should execute in less than 10ms, preferably much faster. We can sometimes split up work into multiple passes but generally the best approach is to make simple and fast algorithms that may not be perfect.

Anti-pattern:
- A bad approach to a component would be when trying to build a new construction: planning everything out super carefully, doing a bunch of ray casts to figure the optimal distances, proving we can link every possible input and output in advance etc. 

Top level goal plan:
1. Bootstrap some production. We try to build where we have the core resources of all types. We kept building miners and furnaces and repeat until we have lots of materials and we're covering these basic ore patches. 
2. Build some basic defenses. We'll have little outposts with turrets fed by an assembler that makes ammo. Power everything with solar power for simplicity. 
3. Build some more construction stuff, some assemblers to make more things we need. too tedious to craft everything by hand. 
4. Establish some science. We're going to have our own science chain and tech tree so let's build some labs and feed them with some assemblers. 
5. Grab more resources from ore deposits further away. We'll set up some miners there and then have the ore all going along a conveyor belt back to our base and process it with furnaces there. 
6. Start to go on the attack. We're going to research some custom artillery, which has much less range than the normal artillery but more than turrets. Then we're going to start building those units and we're going to set up some assemblers to build shells for it. Then what we're going to start doing is spreading out from our base with conveyor belts to carry those artillery. When we get near anything placed by the player, we set out a range and we put down the artillery and defend with a couple of turrets. Then we connect it to the belt and we start shelling the player. Maybe we search with pollution or just directly or randomly. The key is we do have to go on the offensive because if we don't then a player can just ultimately ignore us and play their own game, which is not exciting. 

For step 3, the building (eg a set of assemblers that produces solar panels), this is a good algorithm:
1. Make sure the builder has all required items in inventory: assemblers, inserters, a few power poles, a few conveyor belts, etc. Anything they don't have, craft or fetch ingredients if necessary.
2. Find a spot on the ground to place the basic rectangle of assemblers and connectors, with just a couple squares padding for space for belts to come in. So just a free rectangle of space (could possibly clear trees or rocks here). This should be near our existing base/infra. (For solar we can look for a 16 x 12 rectangle.)
3. Place all this stuff down in the spot
4. Do conveyor belt link up: find the belt types we need eg copper plates, hopefully nearby, add a splitter, then route over to the input we need here. This may involve turning corners, doing underground belts to go around things, etc.
5. Put down power poles. Try to link them to some existing power poles that are connected to solar power.
Note: this is a simple, iterative approach, that is not guaranteed to work, but tries to be relatively robust and work most of the time. It's okay if we end up failing on the conveyor step for example, we can try again in another location. If we have to abandon the plan half way through we don't pick anything back up.
 