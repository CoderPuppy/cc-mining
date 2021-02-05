local m = peripheral.wrap'top'
while true do
	m.transmit(2, 0, 'hi')
	sleep(1)
end
