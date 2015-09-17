interface mProvider {
  m(): void;
}

interface r1 {
  a(): void;
}

interface r2 {
  b(): void;
}

function w(a: r1 | r2 & mProvider): void {
  // `r1 | r2 & mProvider` equiv `r1 | (r2 & mProvider)`
  a.m();
}

function x(a: mProvider & r1 | r2): void {
  // `mProvider & r1 | r2` equiv `(mProvider & r1) | r2`
  a.m();
}
