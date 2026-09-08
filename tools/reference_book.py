#!/usr/bin/env python3
"""Golden reference model for the ITCH-to-Book FPGA.

Mirrors the *exact* semantics of parser.v + book.v so testbenches can check
against it instead of hand computation:

  - message types A / D / E only; every other type is counted past by its
    ITCH 5.0 length and discarded (unknown-to-LUT type: skip 1 byte, resync)
  - bid side only: Add Order with buy/sell byte 'S' (0x53) is dropped
  - order id = low 16 bits of the 8-byte order reference number
  - the book is a fixed array of slots (like the BRAM table), NOT a dict:
      * Add    -> first free slot (or append up to CAPACITY)
      * Delete -> first valid slot whose order id matches -> clear
      * Execute-> first valid slot whose order id matches -> shares -= n;
                  remove only when shares reach zero, then act like Delete
  - best bid = max price over valid slots, or 0 when the book is empty

Run as a CLI to print the best-bid trajectory of a raw feed:

    python3 tools/reference_book.py data/feed.bin
"""

from __future__ import annotations

import sys

# ITCH 5.0 message lengths, offsets from start of message, NO length prefix.
# The FPGA parser carries this same table so it can skip message types it does
# not decode without stalling.
MSG_LEN = {
    ord('S'): 12,   ord('R'): 39,   ord('H'): 25,   ord('Y'): 20,
    ord('L'): 26,   ord('V'): 35,   ord('W'): 12,   ord('K'): 28,
    ord('J'): 35,   ord('h'): 21,   ord('A'): 36,   ord('F'): 40,
    ord('E'): 31,   ord('C'): 36,   ord('X'): 23,   ord('D'): 19,
    ord('U'): 35,   ord('P'): 44,   ord('Q'): 40,   ord('B'): 19,
    ord('I'): 50,   ord('N'): 20,   ord('O'): 48,
}

CAPACITY = 256

BUY = ord('B')
SELL = ord('S')


def _u(b: bytes) -> int:
    return int.from_bytes(b, "big")


class OrderBook:
    def __init__(self, capacity: int = CAPACITY):
        self.capacity = capacity
        # each slot: [valid, order_id, price, shares]
        self.slots: list[list] = []

    # --- book operations -------------------------------------------------
    def _free_slot(self) -> int | None:
        for i, s in enumerate(self.slots):
            if not s[0]:
                return i
        if len(self.slots) < self.capacity:
            self.slots.append([False, 0, 0, 0])
            return len(self.slots) - 1
        return None

    def _find(self, order_id: int) -> int | None:
        for i, s in enumerate(self.slots):
            if s[0] and s[1] == order_id:
                return i
        return None

    def add(self, order_id: int, price: int, shares: int) -> None:
        i = self._free_slot()
        if i is None:
            return  # table full: drop (matches FPGA)
        self.slots[i] = [True, order_id, price, shares]

    def delete(self, order_id: int) -> None:
        i = self._find(order_id)
        if i is not None:
            self.slots[i][0] = False

    def execute(self, order_id: int, shares: int) -> None:
        i = self._find(order_id)
        if i is None:
            return
        self.slots[i][3] -= shares
        if self.slots[i][3] <= 0:
            self.slots[i][0] = False

    @property
    def best_bid(self) -> int:
        best = 0
        for s in self.slots:
            if s[0] and s[2] > best:
                best = s[2]
        return best

    # --- message decode ------------------------------------------------
    @staticmethod
    def decode(msg: bytes):
        """One whole ITCH message -> (type_char, order_id, price, shares) for an
        accepted A/D/E, or None if the message is skipped. Mirrors parser.v:
        price/shares are 0 where the field does not exist for that type."""
        t = msg[0]
        if t == ord('A'):
            if msg[19] == SELL:
                return None
            return ('A', _u(msg[11:19]) & 0xFFFF, _u(msg[32:36]), _u(msg[20:24]))
        if t == ord('D'):
            return ('D', _u(msg[11:19]) & 0xFFFF, 0, 0)
        if t == ord('E'):
            return ('E', _u(msg[11:19]) & 0xFFFF, 0, _u(msg[19:23]))
        return None

    def apply(self, msg: bytes) -> bool:
        """Apply one whole ITCH message. Returns True if it was an accepted
        A/D/E event, False if skipped."""
        ev = self.decode(msg)
        if ev is None:
            return False
        t, oid, price, shares = ev
        if t == 'A':
            self.add(oid, price, shares)
        elif t == 'D':
            self.delete(oid)
        else:
            self.execute(oid, shares)
        return True


def iter_messages(stream: bytes):
    """Walk a concatenated, length-prefix-free ITCH byte stream the same way
    the FPGA parser does: type byte -> length from LUT -> next."""
    i = 0
    n = len(stream)
    while i < n:
        t = stream[i]
        length = MSG_LEN.get(t)
        if length is None:
            i += 1  # unknown type: skip one byte and resync
            continue
        if i + length > n:
            break  # truncated tail
        yield stream[i:i + length]
        i += length


def replay(stream: bytes):
    """Return (trajectory, final, events).
      trajectory : best_bid after every accepted A/D/E event, in order
      final      : best_bid at end
      events     : list of (type_char, order_id, price, shares) actually applied
    """
    book = OrderBook()
    traj: list[int] = []
    events: list[tuple] = []
    for msg in iter_messages(stream):
        ev = book.decode(msg)
        if ev is None:
            continue
        events.append(ev)
        book.apply(msg)
        traj.append(book.best_bid)
    return traj, book.best_bid, events


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: reference_book.py <feed.bin>", file=sys.stderr)
        return 2
    with open(argv[1], "rb") as f:
        stream = f.read()
    traj, final, events = replay(stream)
    for k, (v, ev) in enumerate(zip(traj, events)):
        t, oid, price, shares = ev
        print(f"event {k:4d}  {t} id={oid:5d} price={price:9d} shares={shares:9d}"
              f"   best_bid = {v}")
    print(f"final best_bid = {final}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
