-- Loads every TOC file under the mock, logs in and checks the basics.
dofile("tests/mock.lua")
local function check(c, m) if not c then error("ASSERT: " .. m, 2) end end
LoadAll()
Login({ "party1", "party2" })
check(ns.db and ns.db.rowIcons == true, "defaults not loaded")
check(MamaForever.commands.plus, "/mama plus not registered")
check(MamaForever.messageHandlers.x, "letter x not registered")
check(ns.loggedIn, "LOGIN did not reach MamaPlus")
check(printed[#printed]:find("loaded"), "no loaded line: " .. tostring(printed[#printed]))
check(ns.Options.mode == "sub", "options not under Mama: " .. tostring(ns.Options.mode))
ns.RunCommand("")
ns.RunCommand("status")
ns.RunCommand("test"); Step(0.5)
check(#sounds == 1 and #warnings == 1, "test alert")
Step(9)   -- onto the first beat, 8 s after LOGIN
check(#Sent("H") == 2, "heartbeats after login (the grouping send, then the first beat): " .. #Sent("H"))
print("smoke OK")
