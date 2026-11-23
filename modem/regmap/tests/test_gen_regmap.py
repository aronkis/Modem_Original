import pathlib, subprocess, sys, re
HERE = pathlib.Path(__file__).resolve().parent; REGMAP = HERE.parent; ROOT = REGMAP.parent.parent
sys.path.insert(0, str(REGMAP))
import gen_regmap

def test_header_has_every_witness_and_control():
    h = gen_regmap.render_header(gen_regmap.load(REGMAP / "regmap.toml"))
    for name, addr in [("W1_WITA", 0x214), ("W1_WITB", 0x218), ("R4_WIT", 0x234), ("R4_EXTRAS", 0x238), ("BS_WORDS", 0x23C), ("BS_CNT", 0x258), ("SRO_MODE", 0x25C)]:
        assert re.search(rf"#define QPSK_REG_{name}\s+0x{addr:03X}", h), name
    assert "#define QPSK_FIXCTL_W1_FREEZE_BIT 4" in h
    assert '#define QPSK_R4D_SWAPPED_MD5 "9acbe2ebe1dbf280e030952fc4fc23d8"' in h

def test_inc_rows_are_address_sorted_and_unique():
    inc = gen_regmap.render_inc(gen_regmap.load(REGMAP / "regmap.toml"))
    addrs = [int(m, 16) for m in re.findall(r"\{\s*0x([0-9A-Fa-f]+),", inc)]
    assert addrs == sorted(addrs) and len(addrs) == len(set(addrs))
    assert '{ 0x234, "r4_wit"' in inc and "MS_F_IMGKEY" in inc

def test_check_mode_is_clean_after_generate(tmp_path):
    subprocess.run([sys.executable, str(REGMAP / "gen_regmap.py")], check=True)
    r = subprocess.run([sys.executable, str(REGMAP / "gen_regmap.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr

def test_manifest_has_sro_sign_bit5_and_0x25c():
    m = gen_regmap.load(REGMAP / "regmap.toml")
    steer = m["fixes"]["STEER"]
    controls = steer["control"]
    assert any(c["reg"] == 0x208 and c["bit"] == 5 and c["name"] == "sro_sign" for c in controls)
    witnesses = {w["addr"]: w for w in steer["witness"]}
    assert 0x25C in witnesses and witnesses[0x25C]["name"] == "sro_mode"
    assert "MS_F_PACKED" in witnesses[0x25C]["flags"]

def test_generated_header_defines_sro_sign_bit():
    h = gen_regmap.render_header(gen_regmap.load(REGMAP / "regmap.toml"))
    assert "#define QPSK_FIXCTL_SRO_SIGN_BIT 5" in h
    assert re.search(r"#define QPSK_REG_SRO_MODE\s+0x25C", h)
