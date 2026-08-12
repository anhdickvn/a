# ChatApp v39

v38 keeps v37 UI/layout and changes only:
- Keyboard avoidance: chat transcript is lifted above the software keyboard while typing.
- TAB autocomplete also works for ordinary chat text, not only slash commands. Typing a token such as `xin chao izu` and pressing TAB uses the server Player List to suggest/complete matching online players.
- Existing v37 URL/link colors, GUI item layout, item lore and WASD code are preserved unchanged.


## v39 movement behavior
W/A/S/D are one-shot micro moves: an immediate tiny Player Position step plus one optional short follow-up step. There is no repeating movement timer or post-release burst; server correction cancels the follow-up.
