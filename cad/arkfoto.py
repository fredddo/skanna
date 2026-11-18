"""Foto rakt ovanifrån på referensarket → mått i mm på valfri höjd över arket.

Hittar mätkorsen A–D (kända lägen på arket), räknar kamerans läge (PnP med objektivdata ur EXIF) och kan
räta upp bilden för ett plan på höjden h mm över arket (perspektivet korrigerat).
  from arkfoto import ArkFoto;  f = ArkFoto(path, ungefar={'A':(x,y),...});  f.rektifiera(h, px_per_mm)
"""
import numpy as np
import cv2
from PIL import Image, ImageOps
import pillow_heif

pillow_heif.register_heif_opener()
ARK = {"A": (20.0, 25.0), "B": (190.0, 25.0), "C": (20.0, 277.0), "D": (190.0, 277.0)}  # mm, origo arkets övre vänstra hörn


class ArkFoto:
    def __init__(self, path, ungefar, f35=None):
        im = ImageOps.exif_transpose(Image.open(path))
        exif = im.getexif()
        self.rgb = np.array(im.convert("RGB"))
        self.gray = cv2.cvtColor(self.rgb, cv2.COLOR_RGB2GRAY)
        h, w = self.gray.shape
        if f35 is None:
            try:
                f35 = Image.open(path).getexif().get_ifd(0x8769).get(0xA405)
            except Exception:
                f35 = None
        f35 = f35 or 28
        fpx = f35 * np.hypot(w, h) / 43.27
        self.K = np.array([[fpx, 0, w / 2], [0, fpx, h / 2], [0, 0, 1]], float)
        self.img_pts = np.array([self._kors(*ungefar[k]) for k in "ABCD"], float)
        obj = np.array([[*ARK[k], 0.0] for k in "ABCD"])
        # brännvidden skattas ur korsen (EXIF är bara en startgissning): minsta återprojektionsfel
        best = None
        for f_ in np.linspace(0.6 * fpx, 1.6 * fpx, 201):
            K_ = self.K.copy(); K_[0, 0] = K_[1, 1] = f_
            ok, rv, tv = cv2.solvePnP(obj, self.img_pts, K_, None, flags=cv2.SOLVEPNP_IPPE)
            pr, _ = cv2.projectPoints(obj, rv, tv, K_, None)
            e = np.linalg.norm(pr.reshape(-1, 2) - self.img_pts, axis=1).mean()
            if best is None or e < best[0]:
                best = (e, K_, rv, tv)
        _, self.K, rvec, tvec = best
        self.R, _ = cv2.Rodrigues(rvec)
        self.t = tvec.reshape(3)
        proj, _ = cv2.projectPoints(obj, rvec, tvec, self.K, None)
        self.reproj = np.linalg.norm(proj.reshape(-1, 2) - self.img_pts, axis=1)
        cam = -self.R.T @ self.t
        self.kamerahojd = -cam[2]  # Z in i arket (y nedåt) → höjd = −Z

    def _kors(self, u, v, win=260):
        """Mätkorsets mitt: de två svarta kvartscirklarna ligger diagonalt – mitten är mellan deras tyngdpunkter."""
        h, w = self.gray.shape
        x0, y0 = int(max(u - win, 0)), int(max(v - win, 0))
        crop = self.gray[y0:int(min(v + win, h)), x0:int(min(u + win, w))]
        _, bw = cv2.threshold(crop, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU)
        bw = cv2.morphologyEx(bw, cv2.MORPH_OPEN, np.ones((9, 9), np.uint8))  # bort med tunna linjer/text
        n, lab, stats, cent = cv2.connectedComponentsWithStats(bw)
        best = None
        for i in range(1, n):
            for j in range(i + 1, n):
                ai, aj = stats[i, cv2.CC_STAT_AREA], stats[j, cv2.CC_STAT_AREA]
                if min(ai, aj) < 800 or abs(ai - aj) > 0.35 * max(ai, aj):
                    continue
                d = np.linalg.norm(cent[i] - cent[j])
                r = np.sqrt(ai / (np.pi / 4))           # kvartscirkelns radie ur arean
                if not (0.5 * r < d < 1.2 * r):        # tyngdpunkterna ligger ~0,85 r isär
                    continue
                c = (cent[i] + cent[j]) / 2
                score = np.hypot(c[0] + x0 - u, c[1] + y0 - v)
                if best is None or score < best[0]:
                    best = (score, c)
        # vanligast: hela korset (två kvartscirklar + ring) är en klump – symmetriskt, så tyngdpunkten är mitten
        for i in range(1, n):
            x, y, bw_, bh_, area = stats[i]
            if 80 < bw_ < 400 and 0.8 < bw_ / max(bh_, 1) < 1.25 and 0.3 < area / (bw_ * bh_) < 0.55:
                c = cent[i]
                score = np.hypot(c[0] + x0 - u, c[1] + y0 - v)
                if best is None or score < best[0]:
                    best = (score, c)
        if best is None:
            raise RuntimeError(f"hittade inget mätkors nära ({u:.0f}, {v:.0f})")
        return best[1] + [x0, y0]

    def H(self, h):
        """Homografi från planet h mm över arket (x, y i mm) till bildpixlar."""
        r1, r2, r3 = self.R[:, 0], self.R[:, 1], self.R[:, 2]
        return self.K @ np.c_[r1, r2, -h * r3 + self.t]

    def till_mm(self, uv, h):
        Hinv = np.linalg.inv(self.H(h))
        p = Hinv @ np.r_[uv, 1.0]
        return p[:2] / p[2]

    def rektifiera(self, h, ppmm=5.0, x0=0, y0=0, x1=210, y1=297):
        S = np.array([[1 / ppmm, 0, x0], [0, 1 / ppmm, y0], [0, 0, 1]])
        M = self.H(h) @ S
        size = (int((x1 - x0) * ppmm), int((y1 - y0) * ppmm))
        return cv2.warpPerspective(self.rgb, M, size, flags=cv2.WARP_INVERSE_MAP | cv2.INTER_LINEAR)
