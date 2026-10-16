const BASE = 36;
const T_MIN = 1;
const T_MAX = 26;

const adapt = (delta: number, points: number, first: boolean) => {
  let d = first ? Math.floor(delta / 700) : delta >> 1;
  d += Math.floor(d / points);
  let k = 0;
  while (d > ((BASE - T_MIN) * T_MAX) >> 1) {
    d = Math.floor(d / (BASE - T_MIN));
    k += BASE;
  }
  return k + Math.floor(((BASE - T_MIN + 1) * d) / (d + 38));
};

// 0-25 are a-z, 26-35 are 0-9.
const digit = (d: number) => String.fromCharCode(d + (d < 26 ? 97 : 22));

/** RFC 3492 encoding of one label, without the xn-- prefix. */
const encodeLabel = (label: string) => {
  const input = Array.from(label, (char) => char.codePointAt(0)!);
  let output = input
    .filter((c) => c < 0x80)
    .map((c) => String.fromCharCode(c))
    .join("");
  const basic = output.length;
  if (basic) output += "-";
  let handled = basic;
  let n = 0x80;
  let delta = 0;
  let bias = 72;
  while (handled < input.length) {
    const m = Math.min(...input.filter((c) => c >= n));
    delta += (m - n) * (handled + 1);
    n = m;
    for (const c of input) {
      if (c < n) delta++;
      if (c !== n) continue;
      let q = delta;
      for (let k = BASE; ; k += BASE) {
        const t = k <= bias ? T_MIN : k >= bias + T_MAX ? T_MAX : k - bias;
        if (q < t) break;
        output += digit(t + ((q - t) % (BASE - t)));
        q = Math.floor((q - t) / (BASE - t));
      }
      output += digit(q);
      bias = adapt(delta, handled + 1, handled === basic);
      delta = 0;
      handled++;
    }
    delta++;
    n++;
  }
  return output;
};

/**
 * The ASCII spelling Foundation gives an internationalized hostname. Expo's
 * URL polyfill has no punycode, so `new URL` leaves such a host as it was.
 */
export const domainToAscii = (host: string) =>
  host
    .normalize("NFC")
    .toLowerCase()
    .split(".")
    .map((label) =>
      Array.from(label).every((char) => char.charCodeAt(0) < 0x80)
        ? label
        : `xn--${encodeLabel(label)}`,
    )
    .join(".");
