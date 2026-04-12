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
