#!/usr/bin/env python3
"""Shrink-wrap the ic_speed_*x vector badges to their glyph bounds.

The badges were generated on a fixed wide 277x98 canvas with large empty
margins, so when the media notification fits the drawable into the action
button the digits render small. This re-fits each badge's viewport tightly
around the actual text (with a little padding) and sets the displayed
width/height to the same aspect, so the glyphs fill the button while keeping
correct proportions. Re-runnable.
"""
import glob
import re

PAD = 8  # viewport-unit breathing room around the glyphs
NUM = re.compile(r'-?\d+\.?\d*')


def fmt(v):
    return ('%f' % round(v, 1)).rstrip('0').rstrip('.')


for path in sorted(glob.glob('android/app/src/main/res/drawable/ic_speed_*.xml')):
    with open(path, 'r', encoding='utf-8') as fh:
        xml = fh.read()
    data = re.search(r'android:pathData="([^"]*)"', xml).group(1)
    nums = [float(n) for n in NUM.findall(data)]
    xs, ys = nums[0::2], nums[1::2]
    dx, dy = PAD - min(xs), PAD - min(ys)
    vp_w = round((max(xs) - min(xs)) + 2 * PAD)
    vp_h = round((max(ys) - min(ys)) + 2 * PAD)

    counter = {'i': 0}

    def repl(mo):
        i = counter['i']
        counter['i'] += 1
        v = float(mo.group(0)) + (dx if i % 2 == 0 else dy)
        return fmt(v)

    new_data = NUM.sub(repl, data)
    width = 24 * vp_w / vp_h

    xml = re.sub(r'android:width="[^"]*"', 'android:width="%sdp"' % fmt(width), xml)
    xml = re.sub(r'android:height="[^"]*"', 'android:height="24dp"', xml)
    xml = re.sub(r'android:viewportWidth="[^"]*"', 'android:viewportWidth="%d"' % vp_w, xml)
    xml = re.sub(r'android:viewportHeight="[^"]*"', 'android:viewportHeight="%d"' % vp_h, xml)
    xml = re.sub(r'android:pathData="[^"]*"', lambda _: 'android:pathData="%s"' % new_data, xml)

    with open(path, 'w', encoding='utf-8') as fh:
        fh.write(xml)

print('Tightened', len(glob.glob('android/app/src/main/res/drawable/ic_speed_*.xml')), 'badges')
