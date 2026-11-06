#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import codecs
import os
from io import StringIO


def parseErrTbl():
    print()
    codeclass = []
    errorcode = []
    with codecs.open("appendix_table.a.1.txt", "r", "utf-8") as fin:
        for line in fin:
            line = line.rstrip()
            if line.startswith("Class"):
                arr = line.split("—")
                codeclass.append((arr[0].split(' ')[1], arr[1]))
            else:
                arr = line.split('	')
                errorcode.append((arr[0], arr[1]))
                print("(\"{}\", \"{}\"), ".format(arr[0], arr[1]))
    # print(codeclass)
    # print(errorcode)


if __name__ == '__main__':
    # print("File location using os.getcwd():", os.getcwd())
    parseErrTbl()
