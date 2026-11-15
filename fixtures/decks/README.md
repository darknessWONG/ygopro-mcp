# Test decks (fixtures)

Copies of the decks used by the LAN verification scripts (`verify-battle-target.ps1`,
`verify-battle-policy.ps1`). To use them, copy them into the client's deck folder
(`mycard-bot/game/deck/`) and pass the name without `.ydk` to `-Deck`.

| deck | purpose |
|---|---|
| `battle-test` | cheap high-ATK level-4 monsters; every game reaches the battle phase with two or more attackers, which is what reproduced the MSG_SELECT_CARD attack-target bug |
| `sort-test` | swaps three main-deck cards for Card Shuffle (12183332) — note: Card Shuffle does *not* produce MSG_SORT_CARD in this core |
| `sort2-test` | normal-monster shell used to trigger SORT_CARD from a spell |
| `sort3-test` | includes Card Advance (52112003), which first asks MSG_ANNOUNCE_NUMBER then MSG_SORT_CARD |
| `sort4-test` | 3x 49998907 ("Research on the Immortal" style trap, Duel.SortDecktop(tp,tp,3)) + 37 vanilla monsters: the reliable MSG_SORT_CARD trigger |

Cards that do **not** produce MSG_SORT_CARD: Card Shuffle (12183332), Pot of Duality (98645731).
