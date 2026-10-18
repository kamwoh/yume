// ADR 0095: the one random generator of the spec. xoshiro128** on four
// 32-bit words. Seeding: four steps of a Weyl sequence (+0x9E3779B9), each
// mixed by murmur3 fmix32. randf() = (next >> 8) / 2^24.

export class SpecRandom {
  static shared = new SpecRandom(Date.now());
  private s = new Uint32Array(4);

  constructor(seed = 0) {
    this.setSeed(seed);
  }

  setSeed(seed: number): void {
    let x = Number(BigInt.asUintN(32, BigInt(Math.trunc(seed))));
    for (let i = 0; i < 4; i++) {
      x = (x + 0x9e3779b9) >>> 0;
      let z = x;
      z = Math.imul(z ^ (z >>> 16), 0x85ebca6b) >>> 0;
      z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35) >>> 0;
      this.s[i] = (z ^ (z >>> 16)) >>> 0;
    }
    if (this.s[0] === 0 && this.s[1] === 0 && this.s[2] === 0 && this.s[3] === 0) this.s[0] = 1;
  }

  nextU32(): number {
    const s = this.s;
    const result = Math.imul(rotl(Math.imul(s[1], 5) >>> 0, 7), 9) >>> 0;
    const t = (s[1] << 9) >>> 0;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl(s[3], 11);
    return result;
  }

  randf(): number {
    return (this.nextU32() >>> 8) / 16777216;
  }
}

function rotl(x: number, k: number): number {
  return ((x << k) | (x >>> (32 - k))) >>> 0;
}
