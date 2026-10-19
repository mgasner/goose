"""The input of the Json test, /tmp/1.json, as the suite's generate_json.rb
writes it (JSON.pretty_generate of 524288 random coordinates), for machines
without Ruby. The generator is seeded, so every run writes the same file."""

import json
import os
import random
import string
import sys


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/1.json"
    rnd = random.Random(1)
    coords = []
    for _ in range(524_288):
        coords.append({
            "x": rnd.random() * -10e-30,
            "y": rnd.random() * 10e30,
            "z": rnd.random(),
            "name": "".join(rnd.sample(string.ascii_lowercase, 6)) + " " + str(rnd.randrange(10_000)),
            "opts": {"1": [1, True]},
        })
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", newline="\n") as f:
        json.dump({"coordinates": coords, "info": "some info"}, f, indent=2)


if __name__ == "__main__":
    main()
