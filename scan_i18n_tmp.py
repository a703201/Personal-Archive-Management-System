#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Scan web/src for RAW (non-i18n) Chinese UI strings. v3: classify template regions."""
import re, os

ROOT = "E:/Codes/Project/Archive_manager/web/src"
SKIP = {"i18n/index.ts"}
CAT = {"i18n/catalog.zh-CN.ts","i18n/catalog.en.ts","i18n/catalog.fr.ts"}

CJK = re.compile(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]')
STR_RE = re.compile(r'''('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")''')
FUNCS = {"t","tr","$t"}

def in_comment_before(line, pos):
    i = line.find('//')
    return i != -1 and i < pos

def nearest_func(line, pos):
    stack = 0
    k = pos - 1
    while k >= 0:
        c = line[k]
        if c == ')': stack += 1
        elif c == '(':
            if stack == 0:
                m = re.match(r'\s*([A-Za-z_$][\w$]*)', line[:k][::-1])
                return m.group(1)[::-1] if m else None
            stack -= 1
        k -= 1
    return None

def is_url_path(s):
    if '://' in s: return True
    if s.endswith(('.vue','.ts','.tsx','.js','.png','.jpg','.jpeg','.gif','.svg','.json','.css','.html','.woff','.ttf','.map')):
        return True
    if s.startswith(('.','/','@/','~')): return True
    if re.match(r'^[A-Za-z_][\w./\\-]*$', s) and ('/' in s or '\\' in s): return True
    return False

def scan_script(text):
    res = []
    for ln, line in enumerate(text.splitlines(), 1):
        if line.strip().startswith('//'): continue
        for m in STR_RE.finditer(line):
            inner = m.group(0)[1:-1]
            if not CJK.search(inner): continue
            start = m.start()
            if in_comment_before(line, start): continue
            if is_url_path(inner): continue
            if nearest_func(line, start) in FUNCS: continue
            res.append((ln,'SCRIPT',inner))
    return res

def spans(text, pat):
    out=[]
    for m in re.finditer(pat, text):
        out.append((m.start(), m.end()))
    return out

def in_spans(pos, sp):
    for a,b in sp:
        if a<=pos<b: return True
    return False

def scan_template(tmpl):
    res=[]
    # strip comments
    tmpl2 = re.sub(r'<!--.*?-->', '', tmpl, flags=re.S)
    expr_spans = spans(tmpl2, r'\{\{.*?\}\}')
    # attribute values: attr="..." or attr='...'  (attr may have leading :)
    attr_spans = spans(tmpl2, r'''(?:[:@]?[A-Za-z0-9_\-]+)\s*=\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')''')
    # text nodes: outside expr and attr spans
    n=len(tmpl2); i=0; text_spans=[]
    while i<n:
        if in_spans(i, expr_spans) or in_spans(i, attr_spans):
            i+=1; continue
        j=i+1
        while j<n and not in_spans(j, expr_spans) and not in_spans(j, attr_spans):
            j+=1
        text_spans.append((i,j))
        i=j
    # TEXT nodes: bare CJK runs
    for a,b in text_spans:
        seg=tmpl2[a:b]
        # remove any leftover attr? text spans shouldn't contain tags; but tag boundaries are within spans? tags < > are not in attr/expr spans, so text span may include '>' ... handle: split by tags
        # We'll just locate CJK runs not inside < >
        # simpler: remove everything from '<' to '>'
        seg2=re.sub(r'<[^>]*>', '', seg)
        for mm in re.finditer(r'[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef][\u4e00-\u9fff\u3000-\u303f\uff00-\uffef\s，。、！？：；（）·…—“”‘’%0-9]*', seg2):
            t=mm.group(0).strip()
            if t: res.append((-1,'TEXT',t))
    # quoted literals inside expr and attr spans
    for m in STR_RE.finditer(tmpl2):
        s=m.start(); inner=m.group(0)[1:-1]
        if not CJK.search(inner): continue
        if in_spans(s, expr_spans):
            if nearest_func(tmpl2, s) in FUNCS: continue
            if 't(' in inner or 'tr(' in inner or '$t(' in inner: continue
            res.append((-1,'TPL_EXPR',inner))
        elif in_spans(s, attr_spans):
            if 't(' in inner or 'tr(' in inner or '$t(' in inner: continue
            if is_url_path(inner): continue
            res.append((-1,'ATTR',inner))
    return res

def walk():
    for dirpath, dirs, files in os.walk(ROOT):
        for f in sorted(files):
            if not (f.endswith('.vue') or f.endswith('.ts')): continue
            rel = os.path.relpath(os.path.join(dirpath,f),ROOT).replace('\\','/')
            if rel in SKIP or rel in CAT or rel.startswith('__tests__'): continue
            text=open(os.path.join(dirpath,f),encoding='utf-8').read()
            found=[]
            if f.endswith('.vue'):
                sm=re.search(r'<script[^>]*>(.*?)</script>',text,re.S)
                if sm: found+=scan_script(sm.group(1))
                tm=re.search(r'<template>(.*?)</template>',text,re.S)
                if tm: found+=scan_template(tm.group(1))
            else:
                found+=scan_script(text)
            if found:
                print("### FILE:",rel)
                for r in found:
                    print("   ",r[0],r[1],repr(r[2])[:160])

walk()
