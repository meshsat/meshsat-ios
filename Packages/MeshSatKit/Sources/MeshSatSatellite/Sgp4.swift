// Mirrors satellite/Sgp4.kt: a pure SGP4 propagator for LEO satellites after Vallado's reference
// implementation (2006, AIAA 2006-6753), returning TEME position in km from TLE elements.
// Carries the MESHSAT-1302 corrections (J3OJ2 = J3/J2, un-Kozai'd mean motion in propagation,
// the secular-rate factor, the long-period scaling, Newton stepping towards the root).
// Sgp4ReferenceTests pins it to the reference to within a kilometre.
import Foundation

public enum Sgp4 {
    // WGS-84 constants
    static let earthRadiusKm = 6378.137
    static let j2 = 1.08262998905e-3
    static let j3 = -2.53215306e-6
    static let j4 = -1.61098761e-6
    static let ke = 7.43669161331734e-2  // sqrt(GM) in earth-radii^1.5 per minute
    static let minPerDay = 1440.0
    static let twoPi = 2.0 * Double.pi
    static let deg2rad = Double.pi / 180.0
    static let xpdotp = minPerDay / twoPi  // 229.1831

    static let ck2 = 0.5 * j2
    static let ck4 = -0.375 * j4
    static let qoms2t = 1.880279159015271e-9  // ((120-78)/earthRadiusKm)^4
    static let s = 1.01222928  // 1 + 78/earthRadiusKm
    static let j3oj2 = j3 / j2

    public struct EciPosition: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let z: Double
        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// Propagate a TLE to `tsince` minutes after its epoch. nil when the orbit has decayed.
    public static func propagate(_ tle: TleElements, tsinceMinutes: Double) -> EciPosition? {
        guard let rec = SatRec(tle) else { return nil }
        return rec.propagate(tsince: tsinceMinutes)
    }

    /// The initialised record, kept so a pass scan does not redo the initialisation per step.
    public struct SatRec: Sendable {
        var no: Double  // mean motion (rad/min), the un-Kozai'd value after init
        let ecco: Double
        let inclo: Double
        let nodeo: Double
        let argpo: Double
        let mo: Double
        let bstar: Double

        var isimp = false
        var aodp = 0.0, con41 = 0.0, cc1 = 0.0, cc4 = 0.0, cc5 = 0.0
        var d2 = 0.0, d3 = 0.0, d4 = 0.0, eta = 0.0, argpdot = 0.0, omgcof = 0.0, sinmao = 0.0
        var t2cof = 0.0, t3cof = 0.0, t4cof = 0.0, t5cof = 0.0, x1mth2 = 0.0, x7thm1 = 0.0
        var mdot = 0.0, nodedot = 0.0, xlcof = 0.0, aycof = 0.0, xmcof = 0.0, xnodcf = 0.0
        var delmo = 0.0, con42 = 0.0

        public init?(_ tle: TleElements) {
            let no = tle.meanMotion / Sgp4.xpdotp  // revs/day -> rad/min
            self.no = no
            ecco = tle.eccentricity
            inclo = tle.inclinationDeg * Sgp4.deg2rad
            nodeo = tle.raanDeg * Sgp4.deg2rad
            argpo = tle.argPerigeeDeg * Sgp4.deg2rad
            mo = tle.meanAnomalyDeg * Sgp4.deg2rad
            bstar = tle.bstar

            let cosio = cos(inclo)
            let sinio = sin(inclo)
            let cosio2 = cosio * cosio
            x1mth2 = 1.0 - cosio2
            con42 = 1.0 - 5.0 * cosio2
            con41 = -con42 - cosio2 - cosio2  // 3 cos^2 i - 1
            x7thm1 = 7.0 * cosio2 - 1.0

            let theta2 = cosio2
            let theta4 = theta2 * theta2
            let betao2 = 1.0 - ecco * ecco
            let betao = sqrt(betao2)
            let a1 = pow(Sgp4.ke / no, 2.0 / 3.0)
            let del1 = 1.5 * Sgp4.ck2 * (3.0 * theta2 - 1.0) / (a1 * a1 * betao * betao2)
            let ao = a1 * (1.0 - del1 * (1.0 / 3.0 + del1 * (1.0 + 134.0 / 81.0 * del1)))
            let delo = 1.5 * Sgp4.ck2 * (3.0 * theta2 - 1.0) / (ao * ao * betao * betao2)
            let xnodp = no / (1.0 + delo)
            aodp = ao / (1.0 - delo)
            self.no = xnodp

            let perigee = (aodp * (1.0 - ecco) - 1.0) * Sgp4.earthRadiusKm
            isimp = perigee < 220.0

            var s4 = Sgp4.s
            var qoms24 = Sgp4.qoms2t
            if perigee < 156.0 {
                s4 = perigee < 98.0 ? 20.0 / Sgp4.earthRadiusKm + 1.0 : (perigee - 78.0) / Sgp4.earthRadiusKm + 1.0
                qoms24 = pow((120.0 - (s4 - 1.0) * Sgp4.earthRadiusKm) / Sgp4.earthRadiusKm, 4.0)
            }

            let pinvsq = 1.0 / (aodp * aodp * betao2 * betao2)
            let tsi = 1.0 / (aodp - s4)
            eta = aodp * ecco * tsi
            let etasq = eta * eta
            let eeta = ecco * eta
            let psisq = abs(1.0 - etasq)
            let coef = qoms24 * pow(tsi, 4.0)
            let coef1 = coef / pow(psisq, 3.5)
            let c2 =
                coef1 * xnodp
                * (aodp * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq))
                    + 0.75 * Sgp4.ck2 * tsi / psisq * con41 * (8.0 + 3.0 * etasq * (8.0 + etasq)))
            cc1 = bstar * c2
            let c3 = ecco > 1.0e-4 ? -2.0 * coef * tsi * Sgp4.j3oj2 * xnodp * sinio / ecco : 0.0
            cc4 =
                2.0 * xnodp * coef1 * aodp * betao2
                * (eta * (2.0 + 0.5 * etasq) + ecco * (0.5 + 2.0 * etasq)
                    - 2.0 * Sgp4.ck2 * tsi / (aodp * psisq)
                    * (-3.0 * con41 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta))
                        + 0.75 * x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * cos(2.0 * argpo)))
            cc5 = 2.0 * coef1 * aodp * betao2 * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)

            sinmao = sin(mo)
            if abs(cosio + 1.0) > 1.5e-12 {
                xlcof = -0.25 * Sgp4.j3oj2 * sinio * (3.0 + 5.0 * cosio) / (1.0 + cosio)
            } else {
                xlcof = -0.25 * Sgp4.j3oj2 * sinio * (3.0 + 5.0 * cosio) / 1.5e-12
            }
            aycof = -0.5 * Sgp4.j3oj2 * sinio
            xmcof = ecco > 1.0e-4 ? -(2.0 / 3.0) * coef * bstar / eeta : 0.0
            t2cof = 1.5 * cc1

            let temp1 = 3.0 * Sgp4.ck2 * pinvsq * xnodp
            let temp2 = temp1 * Sgp4.ck2 * pinvsq
            let temp3 = 1.25 * Sgp4.ck4 * pinvsq * pinvsq * xnodp
            mdot = xnodp + 0.5 * temp1 * betao * con41 + 0.0625 * temp2 * betao * (13.0 - 78.0 * theta2 + 137.0 * theta4)
            argpdot =
                -0.5 * temp1 * con42 + 0.0625 * temp2 * (7.0 - 114.0 * theta2 + 395.0 * theta4)
                + temp3 * (3.0 - 36.0 * theta2 + 49.0 * theta4)
            let xhdot1 = -temp1 * cosio
            nodedot = xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * theta2) + 2.0 * temp3 * (3.0 - 7.0 * theta2)) * cosio
            xnodcf = 3.5 * betao2 * xhdot1 * cc1
            omgcof = bstar * c3 * cos(argpo)
            delmo = pow(1.0 + eta * cos(mo), 3.0)

            if !isimp {
                let c1sq = cc1 * cc1
                d2 = 4.0 * aodp * tsi * c1sq
                let temp = d2 * tsi * cc1 / 3.0
                d3 = (17.0 * aodp + s4) * temp
                d4 = 0.5 * temp * aodp * tsi * (221.0 * aodp + 31.0 * s4) * cc1
                t3cof = d2 + 2.0 * c1sq
                t4cof = 0.25 * (3.0 * d3 + cc1 * (12.0 * d2 + 10.0 * c1sq))
                t5cof = 0.2 * (3.0 * d4 + 12.0 * cc1 * d3 + 6.0 * d2 * d2 + 15.0 * c1sq * (2.0 * d2 + c1sq))
            }
        }

        public func propagate(tsince: Double) -> EciPosition? {
            let xmdf = mo + mdot * tsince
            let argpdf = argpo + argpdot * tsince
            let nodedf = nodeo + nodedot * tsince
            var argpm = argpdf
            var mm = xmdf
            let t2 = tsince * tsince
            let nodem = nodedf + xnodcf * t2
            var tempa = 1.0 - cc1 * tsince
            var tempe = bstar * cc4 * tsince
            var templ = t2cof * t2

            if !isimp {
                let delomg = omgcof * tsince
                let delm = xmcof * (pow(1.0 + eta * cos(xmdf), 3.0) - delmo)
                let temp = delomg + delm
                mm = xmdf + temp
                argpm = argpdf - temp
                let t3 = t2 * tsince
                let t4 = t3 * tsince
                tempa -= d2 * t2 + d3 * t3 + d4 * t4
                tempe += bstar * cc5 * (sin(mm) - sinmao)
                templ += t3cof * t3 + t4 * (t4cof + tsince * t5cof)
            }

            let nm = no
            var em = ecco
            let inclm = inclo

            let am = pow(Sgp4.ke / nm, 2.0 / 3.0) * tempa * tempa
            let nm2 = Sgp4.ke / pow(am, 1.5)
            em -= tempe
            if em < 1.0e-6 { em = 1.0e-6 }
            if em >= 1.0 { return nil }  // orbit decayed

            mm += no * templ
            let xlm = mm + argpm + nodem
            let sinim = sin(inclm)
            let cosim = cos(inclm)

            let axn = em * cos(argpm)
            var temp = 1.0 / (am * (1.0 - em * em))
            let ayn = em * sin(argpm) + temp * aycof
            let xl = xlm + temp * xlcof * axn

            var u = (xl - nodem).truncatingRemainder(dividingBy: Sgp4.twoPi)
            if u < 0 { u += Sgp4.twoPi }
            var eo1 = u
            for _ in 0..<10 {
                let sineo1 = sin(eo1)
                let coseo1 = cos(eo1)
                let f = u - eo1 + axn * sineo1 - ayn * coseo1
                let fp = 1.0 - axn * coseo1 - ayn * sineo1
                var delta = f / fp
                if abs(delta) >= 0.95 { delta = delta > 0 ? 0.95 : -0.95 }
                eo1 += delta
                if abs(delta) < 1.0e-12 { break }
            }

            let sineo1 = sin(eo1)
            let coseo1 = cos(eo1)

            let ecose = axn * coseo1 + ayn * sineo1
            let esine = axn * sineo1 - ayn * coseo1
            let el2 = axn * axn + ayn * ayn
            let pl = am * (1.0 - el2)
            if pl < 0.0 { return nil }

            let r = am * (1.0 - ecose)
            let rdot = Sgp4.ke * sqrt(am) * esine / r
            let rvdot = Sgp4.ke * sqrt(pl) / r
            let betal = sqrt(1.0 - el2)
            temp = esine / (1.0 + betal)
            let sinu = am / r * (sineo1 - ayn - axn * temp)
            let cosu = am / r * (coseo1 - axn + ayn * temp)
            var su = atan2(sinu, cosu)

            let sin2u = 2.0 * sinu * cosu
            let cos2u = 2.0 * cosu * cosu - 1.0
            let temp1 = Sgp4.ck2 / pl
            let temp2 = temp1 / pl

            let rk = r * (1.0 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
            su -= 0.25 * temp2 * x7thm1 * sin2u
            let xnode = nodem + 1.5 * temp2 * cosim * sin2u
            let xinc = inclm + 1.5 * temp2 * cosim * sinim * cos2u
            _ = rdot - nm2 * temp1 * x1mth2 * sin2u
            _ = rvdot + nm2 * temp1 * (x1mth2 * cos2u + 1.5 * con41)

            if rk < 1.0 { return nil }  // orbit decayed

            let sinsu = sin(su)
            let cossu = cos(su)
            let sinno = sin(xnode)
            let cosno = cos(xnode)
            let sini = sin(xinc)
            let cosi = cos(xinc)

            let xmx = -sinno * cosi
            let xmy = cosno * cosi
            let ux = xmx * sinsu + cosno * cossu
            let uy = xmy * sinsu + sinno * cossu
            let uz = sini * sinsu

            let rkm = rk * Sgp4.earthRadiusKm
            return EciPosition(x: rkm * ux, y: rkm * uy, z: rkm * uz)
        }
    }
}
