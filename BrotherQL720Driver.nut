class QL720Driver extends DriverBase {

    static VID = 0x04f9;
    static PID = 0x2044;
    static QL720_REQUEST_FTDI_OUT = 0x40;
    static QL720_SIO_SET_BAUD_RATE = 3;
    static QL720_SIO_SET_FLOW_CTRL = 2;
    static QL720_SIO_DISABLE_FLOW_CTRL = 0;

    _deviceAddress = null;
    _controlEndpoint = null;
    _bulkIn = null;
    _bulkOut = null;

    function _typeof() {
        return "BrotherQL720Printer";
    }

    function _setupEndpoints(deviceAddress, speed, descriptors) {
        server.log(format("Driver connecting at address 0x%02x", deviceAddress));
        _deviceAddress = deviceAddress;
        _controlEndpoint = ControlEndpoint(_usb, deviceAddress, speed, descriptors["maxpacketsize0"]);

        // Select configuration
        local configuration = descriptors["configurations"][0];
        server.log(format("Setting configuration 0x%02x (%s)", configuration["value"], _controlEndpoint.getStringDescriptor(configuration["configuration"])));
        _controlEndpoint.setConfiguration(configuration["value"]);

        // Select interface
        local interface = configuration["interfaces"][0];
        local interfacenumber = interface["interfacenumber"];

        foreach (endpoint in interface["endpoints"]) {
            local address = endpoint["address"];
            local maxPacketSize = endpoint["maxpacketsize"];
            if ((endpoint["attributes"] & 0x3) == 2) {
                if ((address & 0x80) >> 7 == USB_DIRECTION_OUT) {
                    _bulkOut = BulkOutEndpoint(_usb, speed, _deviceAddress, interfacenumber, address, maxPacketSize);
                } else {
                    _bulkIn = BulkInEndpoint(_usb, speed, _deviceAddress, interfacenumber, address, maxPacketSize);
                }

            }
        }
    }

    function _configure(device) {
        server.log(format("Configuring for device version 0x%04x", device));

        // Set Baud Rate
        local baud = 115200;
        local baudValue;
        local baudIndex = 0;
        local divisor3 = 48000000 / 2 / baud; // divisor shifted 3 bits to the left

        if (device == 0x0100) { // FT232AM
            if ((divisor3 & 0x07) == 0x07) {
                divisor3++; // round x.7/8 up to x+1
            }

            baudValue = divisor3 >> 3;
            divisor3 = divisor3 & 0x7;

            if (divisor3 == 1) {
                baudValue = baudValue | 0xc000; // 0.125
            } else if (divisor3 >= 4) {
                baudValue = baudValue | 0x4000; // 0.5
            } else if (divisor3 != 0) {
                baudValue = baudValue | 0x8000; // 0.25
            }

            if (baudValue == 1) {
                baudValue = 0; /* special case for maximum baud rate */
            }

        } else {
            local divfrac = [0, 3, 2, 0, 1, 1, 2, 3];
            local divindex = [0, 0, 0, 1, 0, 1, 1, 1];

            baudValue = divisor3 >> 3;
            baudValue = baudValue | (divfrac[divisor3 & 0x7] << 14);

            baudIndex = divindex[divisor3 & 0x7];

            /* Deal with special cases for highest baud rates. */
            if (baudValue == 1) {
                baudValue = 0; // 1.0
            } else if (baudValue == 0x4001) {
                baudValue = 1; // 1.5
            }
        }
        // server.log("Baud rate is:"+baudValue);
        baudValue = 9600;
        _controlEndpoint.send(FTDI_REQUEST_FTDI_OUT, FTDI_SIO_SET_BAUD_RATE, baudValue, baudIndex);

        local xon = 0x11;
        local xoff = 0x13;

        _controlEndpoint.send(FTDI_REQUEST_FTDI_OUT, FTDI_SIO_SET_FLOW_CTRL, xon | (xoff << 8), FTDI_SIO_DISABLE_FLOW_CTRL << 8);
    }

    function _start() {
        _bulkIn.read(blob(64 + 2));
    }

    function write(data) {

        _bulkOut.write(data);

    }

    function connect(deviceAddress, speed, descriptors) {
        _setupEndpoints(deviceAddress, speed, descriptors);

        // _configure(descriptors["device"]);
        _start();
    }

    function transferComplete(eventdetails) {
        local direction = (eventdetails["endpoint"] & 0x80) >> 7;
        if (direction == USB_DIRECTION_IN) {
            local readData = _bulkIn.done(eventdetails);
            if (readData.len() < 3) {
                _bulkIn.read(blob(64 + 2));
            } else {
                // Don't skip the first 2 bytes, we want to see all 32 bytes
                // readData.seek(2);
                local writeData = blob(readData.len() + 3);
                server.log(readData.readblob(readData.len()).tostring());

                // writeData.writestring("ACK");
                // writeData.writeblob(readData);
                // local writeData = readData.readblob(readData.len()-2);
                _bulkOut.write(writeData);
                readData.seek(0);
                _bulkIn.read(blob(64 + 2));
            }
        } else if (direction == USB_DIRECTION_OUT) {
            _bulkOut.done(eventdetails);
        }
    }
}
