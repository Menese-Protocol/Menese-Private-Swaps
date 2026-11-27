//! Pure price arithmetic: decimal parsing, the conversion to the canister's unit, and the
//! reporter's own median and disagreement rule. No I/O here, so every rule is unit-tested.

use num_bigint::BigUint;
use num_traits::{One, Zero};

/// A decimal quote: `mantissa / 10^scale`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Quote {
    pub mantissa: BigUint,
    pub scale: u32,
}

/// Parse a plain decimal ("64321.5", "0.000123"); refuses signs, exponents, empty parts and zero.
pub fn parse_decimal(s: &str) -> Option<Quote> {
    let s = s.trim();
    if s.is_empty() || s.len() > 64 {
        return None;
    }
    let (int, frac) = match s.split_once('.') {
        Some((i, f)) => (i, f),
        None => (s, ""),
    };
    if int.is_empty() && frac.is_empty() {
        return None;
    }
    if !int.chars().all(|c| c.is_ascii_digit()) || !frac.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let digits = format!("{int}{frac}");
    let mantissa = BigUint::parse_bytes(digits.as_bytes(), 10)?;
    if mantissa.is_zero() {
        return None;
    }
    Some(Quote { mantissa, scale: frac.len() as u32 })
}

fn pow10(n: u32) -> BigUint {
    let mut x = BigUint::one();
    for _ in 0..n {
        x *= 10u32;
    }
    x
}

/// The canister's unit: ICP e8s per asset base unit, times 10^18, from one venue's asset and ICP
/// prices in the same quote currency (the quote currency cancels). Rounded down.
pub fn feed_price(asset: &Quote, icp: &Quote, asset_decimals: u32) -> Option<BigUint> {
    if asset.mantissa.is_zero() || icp.mantissa.is_zero() || asset_decimals > 18 {
        return None;
    }
    let num = &asset.mantissa * pow10(icp.scale + 8 + 18);
    let den = &icp.mantissa * pow10(asset.scale + asset_decimals);
    let p = num / den;
    if p.is_zero() {
        None
    } else {
        Some(p)
    }
}

/// The lower median, as the canister takes it: sorted[(n - 1) / 2].
pub fn lower_median(xs: &[BigUint]) -> Option<BigUint> {
    if xs.is_empty() {
        return None;
    }
    let mut v = xs.to_vec();
    v.sort();
    Some(v[(v.len() - 1) / 2].clone())
}

/// |a - b| * 10_000 <= b * bps
pub fn within(a: &BigUint, b: &BigUint, bps: u32) -> bool {
    let diff = if a >= b { a - b } else { b - a };
    diff * 10_000u32 <= b * bps
}

#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    Report(BigUint),
    Refuse(String),
}

/// Report the median of at least `min_sources` venues, only if every venue is within
/// `max_disagreement_bps` of it. Never an average: venues that disagree mean no report.
pub fn aggregate(prices: &[BigUint], min_sources: usize, max_disagreement_bps: u32) -> Verdict {
    if prices.len() < min_sources {
        return Verdict::Refuse(format!("{} of {} venues answered", prices.len(), min_sources));
    }
    let m = lower_median(prices).expect("non-empty");
    for p in prices {
        if !within(p, &m, max_disagreement_bps) {
            return Verdict::Refuse(format!("venues disagree beyond {max_disagreement_bps} bps"));
        }
    }
    Verdict::Report(m)
}

/// The price as the canister's interface takes it, `hi * 2^64 + lo`; `None` at 2^128 or above,
/// which the canister refuses anyway (its largest price is 2^128 - 1).
pub fn wire_price(p: &BigUint) -> Option<(u64, u64)> {
    if p.bits() > 128 {
        return None;
    }
    let mask = BigUint::from(u64::MAX);
    let lo = u64::try_from(p & &mask).ok()?;
    let hi = u64::try_from(p >> 64u32).ok()?;
    Some((hi, lo))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(x: u128) -> BigUint {
        BigUint::from(x)
    }

    #[test]
    fn parses_and_refuses() {
        assert_eq!(parse_decimal("64321.50"), Some(Quote { mantissa: b(6432150), scale: 2 }));
        assert_eq!(parse_decimal("7"), Some(Quote { mantissa: b(7), scale: 0 }));
        assert_eq!(parse_decimal(".5"), Some(Quote { mantissa: b(5), scale: 1 }));
        for bad in ["", ".", "-1", "1e5", "0", "0.000", "1.2.3", " ", "1,5", "+2"] {
            assert_eq!(parse_decimal(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn unit_conversion_matches_hand_computation() {
        // BTC 60000 USD, ICP 6 USD -> 10000 ICP per BTC = 10^12 e8s per 10^8 sat = 10^4 e8s/sat
        let p = feed_price(&parse_decimal("60000").unwrap(), &parse_decimal("6.00").unwrap(), 8).unwrap();
        assert_eq!(p, b(10_000u128 * 1_000_000_000_000_000_000));
        // an 18-decimal asset at 3000 USD, ICP 6 USD: 500 ICP per 10^18 base units
        let p = feed_price(&parse_decimal("3000").unwrap(), &parse_decimal("6").unwrap(), 18).unwrap();
        assert_eq!(p, b(500u128 * 100_000_000)); // 500 * 10^8 e8s / 10^18 units * 10^18
        assert_eq!(feed_price(&parse_decimal("1").unwrap(), &parse_decimal("1").unwrap(), 19), None);
    }

    #[test]
    fn median_is_lower_and_never_a_mean() {
        assert_eq!(lower_median(&[b(1), b(100)]), Some(b(1)));
        assert_eq!(lower_median(&[b(3), b(1), b(2)]), Some(b(2)));
        assert_eq!(lower_median(&[b(4), b(1), b(3), b(2)]), Some(b(2)));
    }

    #[test]
    fn one_liar_cannot_move_the_report_but_refuses_it() {
        let honest = [b(1_000_000), b(1_000_100), b(999_950)];
        assert_eq!(aggregate(&honest, 3, 50), Verdict::Report(b(1_000_000)));
        // a planted outlier: the median would not move, but the reporter refuses to report
        let planted = [b(1_000_000), b(1_000_100), b(999_950), b(2_000_000)];
        assert!(matches!(aggregate(&planted, 3, 50), Verdict::Refuse(_)));
        // too few venues
        assert!(matches!(aggregate(&honest[..2], 3, 50), Verdict::Refuse(_)));
        // exactly at the bound passes, one unit past it refuses
        assert_eq!(aggregate(&[b(10_000), b(10_050), b(10_000)], 3, 50), Verdict::Report(b(10_000)));
        assert!(matches!(aggregate(&[b(10_000), b(10_051), b(10_000)], 3, 50), Verdict::Refuse(_)));
    }

    #[test]
    fn a_quote_currency_depeg_cancels_per_venue() {
        // USD and USDT venues pooled into one median split apart when USDT depegs. Here
        // each venue's two legs are in that venue's own quote, so the ratio is the same at a 5 %
        // depeg (USDT at 0.95 USD: both USDT quotes are 1/0.95 higher) and the venues agree.
        let usd = feed_price(&parse_decimal("60000").unwrap(), &parse_decimal("6.00").unwrap(), 8).unwrap();
        let usdt = feed_price(&parse_decimal("63157.89").unwrap(), &parse_decimal("6.315789").unwrap(), 8).unwrap();
        assert!(within(&usdt, &usd, 1), "{usdt} vs {usd}");
        assert!(matches!(aggregate(&[usd.clone(), usdt.clone(), usd.clone(), usdt.clone()], 3, 50), Verdict::Report(_)));
        // the same depeg applied to one leg only (the pooled-quote mistake) is 5 % off and refused
        let mixed = feed_price(&parse_decimal("63157.89").unwrap(), &parse_decimal("6.00").unwrap(), 8).unwrap();
        assert!(matches!(aggregate(&[usd.clone(), mixed.clone(), usd, mixed], 3, 50), Verdict::Refuse(_)));
    }

    #[test]
    fn wire_price_splits_and_refuses_above_2_128() {
        let max = (BigUint::one() << 128u32) - BigUint::one();
        assert_eq!(wire_price(&max), Some((u64::MAX, u64::MAX)));
        assert_eq!(wire_price(&(BigUint::one() << 128u32)), None);
        let p = (BigUint::from(7u64) << 64u32) + BigUint::from(9u64);
        assert_eq!(wire_price(&p), Some((7, 9)));
        assert_eq!(wire_price(&BigUint::from(5u64)), Some((0, 5)));
        // round trip on a realistic feed price (1 BTC = 30,000 ICP, 8 decimals, scale 10^18)
        let q = BigUint::parse_bytes(b"30000000000000000000000", 10).unwrap();
        let (hi, lo) = wire_price(&q).unwrap();
        assert_eq!((BigUint::from(hi) << 64u32) + BigUint::from(lo), q);
    }
}
