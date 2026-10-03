# Infinity Arcade Session Pricing Policy

## Every session
- A game session lasts **at most 2 hours** from payment. After that it expires: the arcade shows SESSION EXPIRED and the next Play charges again.
- Pressing **Close** ends the session at any time.

## Ticket games: one payment = one run
- The arcade charges the game's Token price when the player presses Play; this opens one paid **run**.
- The game decides when the run ends (lives, timer, etc.) and then sends **one** final score (`arcade-latest-score`).
- The **first** score message of a run is final; later ones are ignored until a new run is paid for. The arcade shows a small "Run over - final score" label.
- The player presses **Submit Score** to be paid Tickets from the game's 8-level ladder (0-7 Tickets), or **Close** to discard the run.
- Paying again while a previous run is still open starts a new run and forfeits the unsubmitted one.
- Games must not offer an in-game "Play again" after the final score.

## Non-ticket games: one payment = one visit
- One payment opens a **visit**: play, die and restart freely until Close or the 2-hour limit.
- Progress can be saved with **on-chain checkpoints** (`arcade-checkpoint` / `arcade-load-checkpoint` / `arcade-clear-checkpoint`; max 32,000 characters; publicly readable, so no private data).
- **Owners** (bought outright, or auto-unlocked once their total spend reaches the purchase price) play **free**.

## Not available
- In-game continues (`arcade-request-coin` is answered "Continues are not available yet"; planned).
- Demo / "Try" plays (retired).

## Splits (per Token spent)
- Ticket games: 80% ticket pool (8 Tickets per Token), 10% creator, 5% arcade, 5% DAO.
- Non-ticket games (plays and purchases): 50% creator, 30% arcade, 20% DAO.
