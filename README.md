# Bags Forever

All your bags in one window for World of Warcraft: Forever, with a button to sort them. The game's sort button went missing after a patch and I wanted it back, so I ended up writing the whole bag window.

It opens instead of the game's bags: B, the backpack button and the bag buttons all open it, and vendors, the bank and the mailbox open and close it the way they did the game's. Escape closes it. Drag the title to move it. It grows downwards, so the buttons at the top stay where they are.

Type in the search box and everything that doesn't match fades out. It looks at the name, the type, the slot and the quality.

The bag button next to Sort shows your bags in a row. Hover one and its slots light up. Click to pick it up, or drop another bag on it to swap them. Right click leaves it out of sorting and gives it a red cross, and shift-click hides its slots in the window (saved per character). The fifth bag slot, the one for reagent, herb or soul bags, always gets its own row with tinted slots. The key at the end of the row shows the keyring.

Slots get a border in the item's quality colour, the item level on weapons and armour, a coin on junk and a gold border on quest items. New items glow until you hover them or close your bags, and what you've already seen stays seen after a reload.

At the bottom there are the free slots, the currencies you track and your gold. With Alters Forever installed, hovering the gold shows what every character has.

At a vendor it sells your junk and tells you how much you got. It can repair your gear too, but that's off until you turn it on.

The bank looks the same, with its own search box, sort button and row of bank bags. The + at the end of that row buys another bag slot. The game only lets its own buttons buy them, so the + clicks the bank's buy button for you and the game asks you to confirm.

The gear button opens the options: the theme (the same ones as Alters Forever), columns, scale, a row per bag, and switches for all of the above, including whether it replaces the game's bags and bank.

## Commands

| Command | What it does |
| --- | --- |
| `/bf` | Open or close the bags |
| `/bf sort` | Sort the bags |
| `/bf options` | Open the options |
| `/bf reset` | Put the windows back in place, at normal size |

Translated into the ten WoW client languages. Other languages use English.

Made for World of Warcraft: Forever 1.60.1 (`Interface: 16001`).

## Installation

1. Extract the `BagsForever` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\`
2. Restart the game.
3. Check that it's enabled in the AddOns list on the character screen.
