classdef Epos2Controller < handle
    %EPOS2CONTROLLER Serial port interface to Maxon EPOS2 motor controllers
    %   
    %
    
    % ----------------------------------------------------
    %  Public properties
    % ----------------------------------------------------
    properties(Access=public)
        serial_portname = 'COM1';   % Set to serial port name to be open in connect()
        serial_baudrate = 115200;   % Desired serial port baudrate
        node_id         = uint8(1); % The target node ID (See EPOS2 docs)
        
        
    end % end public props
    
    % ----------------------------------------------------
    %  Public methods
    % ----------------------------------------------------
    methods(Access=public)
        function [me] = Epos2Controller()
            % Default constructor.
        end 
        function [] = delete(me)
            % Destructor.
            me.disconnect();
        end 

        function [ok] = connect(me)
            % Tries to establish connection to the serial port. The first
            % time it is called it tries to query the firmware model just
            % to make sure the comms are OK. 
            % Returns true (1) if succeds
            if (~isempty(me.m_serial))
                ok=true;
                return;
            end
            
            me.m_serial = serial(...
                me.serial_portname,...
                'BaudRate',me.serial_baudrate,...
                'Databits', 8,...
                'Parity', 'none',...
                'StopBits', 1,...
                'InputBufferSize', 1024,...
                'OutputBufferSize', 1024);
            me.m_serial.ReadAsyncMode = 'continuous';  % Continuously query data in background

            % Tries to open:
            try
                fprintf('[Epos2Controller] Trying to open serial port "%s"...\n',me.serial_portname);
                fopen(me.m_serial);
            catch
               % 
            end
            if (~strcmp(me.m_serial.status,'open'))
                me.m_serial = [];
                errordlg(sprintf('[Epos2Controller] ERROR: Could not open serial port "%s"',me.serial_portname'), 'Connect Error');
                ok=false; return;
            end
            ok=true;
        end % end connect()
        
        function [] = disconnect(me)
            if (~isempty(me.m_serial))
                fprintf('Closing serial port "%s"...\n',me.serial_portname);
                fclose(me.m_serial);
                me.m_serial=[];
            end
        end  % end disconnect()
        
        
        function [ok] = send(me, frame)
            % Generic method to send a frame to epos2, checking for errors, etc.
            % Returns 0(false) on any error, timeout,...
            
            % Make sure we're connected:
            if (~me.connect())
                ok=false; return;
            end
            
            frame.data(2) = bitor(...
                bitshift(me.node_id,8),...
                bitand(frame.data(2), h('0x00ff')));
            frame.crc=frame.calc_crc();
            
            retries=0;
            nRead=0;
            while(nRead==0)
                retries=retries+1;
                if(retries>5)
                    ok=false; return;
                end
                flushinput(me.m_serial); % make sure there're no pending input
                fwrite(me.m_serial, frame.opcode,'uint8'); % OPCODE

                % Wait for answer:
                [c,nRead]=fread(me.m_serial,1,'uint8');                    
            end

            if (c=='O')
                fwrite(me.m_serial, frame.len,'uint8'); % LENGTH
                assert(length(frame.data)==(1+frame.len));
                for i=1:(1+frame.len),
                    fwrite(me.m_serial, bitand(frame.data(i),h('0xff')),'uint8'); % Low byte
                    fwrite(me.m_serial, bitsrl(frame.data(i),8),'uint8'); % High byte
                end
                fwrite(me.m_serial, bitand(frame.crc,h('0xff')),'uint8'); % Low byte
                fwrite(me.m_serial, bitsrl(frame.crc,8),'uint8'); % High byte
                ok=true; 
                return;
            else
                warning('[Epos2Controller] Invalid ACK received: "%c"',c);
                ok=false; 
                return;
            end           
                        
        end % end send()
        
    end % end public methods
    
    % ----------------------------------------------------
    %  PRIVATE methods
    % ----------------------------------------------------
    methods(Access=protected)
        

    end % end methods
    
    % ----------------------------------------------------
    %  Private properties
    % ----------------------------------------------------
    properties(Access=protected)
        m_serial = []; % Serial port object
        
    end % end protected props    
end
