classdef Epos2Controller < handle
    %EPOS2CONTROLLER Serial port interface to Maxon EPOS2 motor controllers
    %   
    %
    
    % ----------------------------------------------------
    %  Public properties
    % ----------------------------------------------------
    properties(Access=public)
        serial_portname = 'COM3';   % Set to serial port name to be open in connect()
        serial_baudrate = 115200;   % Desired serial port baudrate
        node_id         = uint8(1); % The target node ID (See EPOS2 docs)
		usb_protocol    = 0;        % If !=0, send the SYNC frame header and do data 'stuff' (See Maxon Comm.Guide). Use only when connecting through USB link. This is *NOT* the same than RS232 thru a USB-RS232 converter!!
        verbosity_level = 2;        % 0=quiet. 1=shows comms info. 2=shows all comms data and details
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
            % Tries to establish connection to the serial port.
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
                if (me.verbosity_level>=1)
                    fprintf('[Epos2Controller] Trying to open serial port "%s"...\n',me.serial_portname);
                end
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
                if (me.verbosity_level>=1)
                    fprintf('Closing serial port "%s"...\n',me.serial_portname);
                end                    
                fclose(me.m_serial);
                me.m_serial=[];
            end
        end  % end disconnect()
        
        
        function [ok]=send_and_wait_answer(me,frame)
            % Calls send(), then wait for EPOS2 ack and/or response.
            ok = me.send(frame);
            if (~ok)
                return;  % error sending
            end
            
            if (me.usb_protocol)
                % USB: EPOS2 answers with a complete frame:
                % ------------------------------
                expected_answer = [me.DLE, me.STX, 0 ];  % 0: answer opcode
                for k=1:length(expected_answer)
                    [c,nRead]=fread(me.m_serial,1,'uint8');
                    if (nRead~=1)
                        if (me.verbosity_level>=1)
                            warning('Timeout waiting for EPOS2 response');
                        end
                        ok=false; return;
                    end
                    if (c~=expected_answer(k))
                        if (me.verbosity_level>=1)
                            warning('Expecting RX=%02X, Actual RX=%02X!',expected_answer(k),c);
                        end
                        ok=false; return;
                    end
                end
                
            else
                % RS232: Wait for EPOS2 ack frame:
                % ------------------------------
                % OPCODE     ( -> ACK) 
                % LEN-1 | (DATA) | CRC   (-> ACK)
                [c,nRead]=fread(me.m_serial,1,'uint8');
                if (nRead~=1)
                    if (me.verbosity_level>=1)
                        warning('Timeout waiting for EPOS2 response');
                    end
                    ok=false; return;
                end
                % OPCODE should 0
                if (c~=0)
                    if (me.verbosity_level>=1)
                        warning('Expecting OPCODE=0!!');
                    end
                    ok=false; return;
                end
                % send ACK:
                me.sendByte('O');
            end  % end RS-232
            
            % Receive len & data:
            [LEN_1,nRead]=fread(me.m_serial,1,'uint8');
            if (nRead~=1)
                if (me.verbosity_level>=1)
                    warning('Timeout waiting for EPOS2 response len');
                end
                ok=false; return;
            end
            LEN=LEN_1+1;
            [RESP,nRead]=fread(me.m_serial,LEN+1,'uint16');
            if (nRead~=LEN+1)
                if (me.verbosity_level>=1)
                    warning('Timeout waiting for EPOS2 response data');
                end
                ok=false; return;
            end
            % TODO: Check CRC.
            if (me.verbosity_level>=2)
                fprintf('Response: ');
                for i=1:(LEN+1)
                    fprintf('0x%04X ',RESP(i));
                end
                fprintf('\n');
            end
            
            % (Only RS-232) send ACK:
            if (~me.usb_protocol)
                me.sendByte('O');
            end
            
            % All fine.
            ok= true;            
        end
        
        function [ok] = send(me, frame)
            % Generic method to send a frame to epos2, checking for errors, etc.
            % Returns 0(false) on any error, timeout,...
            
            % Make sure we're connected:
            if (~me.connect())
                ok=false; return;
            end
            
            % d(2) = (node_id << 8) | (d(2) & 0x00FF)
            frame.data(2) = bitor(...
                uint16(bitshift(uint16(me.node_id),8)),...
                bitand(frame.data(2),h('0x00ff')));
            frame.crc=frame.calc_crc();
            
            nData = length(frame.data);
            len=uint8(nData-1);
            
            if (me.usb_protocol)
                % USB protocol ------------------
                % Send DLE + STD bytes before opcode (they don't count for CRC computation):
                me.sendByte(me.DLE);
                me.sendByte(me.STX);        
                me.sendByteWithStuffing(frame.opcode);      % OPCODE
                me.sendByteWithStuffing(len);               % LENGTH
                for i=1:nData,  
                    me.sendWordWithStuffing(frame.data(i)); % DATA
                end
                me.sendWordWithStuffing(frame.crc);         % CRC
            else
                % RS232 protocol ------------------
                retries=0;
                nRead=0;
                while(nRead==0)
                    retries=retries+1;
                    if(retries>5)
                        ok=false; return;
                    end
                    if(retries>1)
                        flushinput(me.m_serial); % make sure there're no pending input
                        pause(0.1);
                    end
                    me.sendByte(frame.opcode); % OPCODE

                    % Wait for answer:
                    [c,nRead]=fread(me.m_serial,1,'uint8');                    
                end
                
                if (c=='O')
                    me.sendByte(len); % LENGTH
                    for i=1:nData,
                        me.sendWord(frame.data(i));
                    end
                    me.sendWord(frame.crc);

                    % Wait for ack:
                    [c,nRead]=fread(me.m_serial,1,'uint8');                    

                    if (nRead==1 && c=='O')
                        ok=true;
                        if (me.verbosity_level>=2)
                            fprintf('ACK OK\n');
                        end
                        return;
                    else
                        if (me.verbosity_level>=1)
                            warning('[Epos2Controller] Invalid EndACK received: "%c"',c);
                        end
                        ok=false; 
                        return;
                    end
                else
                    if (me.verbosity_level>=1)
                        warning('[Epos2Controller] Invalid ACK received: "%c"',c);
                    end
                    ok=false; 
                    return;
                end
            end  % end case of RS232 protocol
        end % end send()

        function [ok]=cmd_enable(me)
            % Enable the EPOS2:
            %Control word Firmware Specification- Section 8.2.85
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('60','40'), makewordh('01','00'), makewordh('00','06'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
            if (~ok) 
                return;
            end
            pause(0.25);
            
            f.data=[makewordh('60','40'), makewordh('01','00'), makewordh('00','0F'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);     
            if (~ok) 
                return;
            end
            pause(0.25);

            f.data=[makewordh('60','40'), makewordh('01','00'), makewordh('01','0F'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);                
            
        end
        
        function [ok]=cmd_disable(me)            

           %Disable Operation
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('60','40'), makewordh('01','00'), makewordh('00','06'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
    
            %You can disconnect the object by typing "clear" or "motor1.disconnect()"
        end
        
        function [ok]=cmd_homing(me)
               
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('60','60'), makewordh('01','00'), makewordh('00','06'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
        end
        
        function[ok]=cmd_startProfilePositionMode(me,profileVelocity)
            
            profileVelocity_hex = dec2hex(profileVelocity, 4);
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('60','81'), makewordh('01','00'), makewordh((profileVelocity_hex),'00'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);

            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('60','60'), makewordh('01','00'), makewordh('00','01'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
    
        end
        
        function[ok]=cmd_startPositionMode(me)
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('60','60'), makewordh('01','00'), makewordh('00','FF'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
        end
        
        function[ok]=cmd_MaximalFollowingError(me)
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('65','60'), makewordh('00','01'), makewordh('20','4E'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
        end
        
        
         
        function [ok]=cmd_sendTargetPosition(me,pos)
            
            %Absolute
            %Sets the TargetPosition for Profile Position mode
            %position must be an integer.
            
            pos = round(pos); % Eliminate fractional part

            if pos >= 0
                pos_hex = dec2hex(pos, 8);
            else
                pos_hex = dec2hex(2^32+pos, 8);
            end
               
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('20','62'), makewordh('01','00'), makewordh(pos_hex(1:4),pos_hex(5:8)), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
            
        end
        
            
         function [ok]=cmd_sendVelocity(me, vel)
            % Enable the EPOS2:
            %Control word Firmware Specification- Section 8.2.85
            
            %Sets the Velocity mode = setting value
            %vel an integer.

            vel = round(vel); % Eliminate fractional part
            if vel >= 0
                vel_hex = dec2hex(vel, 8);
            else
                vel_hex = dec2hex(2^32+vel, 8);
            end
            
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('20','6B'), makewordh('01','00'), makewordh(vel_hex(1:4),vel_hex(5:8)), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
         end
        
        function [ok]=cmd_startVelocityMode(me)
               
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('60','60'), makewordh('01','00'), makewordh('00','FE'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
        end
        
        function [ok]=cmd_startCurrentMode(me)
               
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('60','60'), makewordh('01','00'), makewordh('00','FD'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
        end
        
        function [ok]=cmd_sendCurrent(me,curr)
            %Sets the Current Mode Setting Value. Curr is in mA
            % current must be an integer
            
            curr_hex = '';
            curr = round(curr);

            if curr >= 0
                curr_hex = dec2hex(curr, 4);
            else
                curr_hex = dec2hex(2^16+curr, 4);
            end
               
            f=epos2_frame();
            f.opcode=epos2_frame.WRITE_OPCODE;
            f.data=[makewordh('20','30'), makewordh('01','00'), makewordh('(curr_hex)','00'), makewordh('00','00')];
            ok=me.send_and_wait_answer(f);
        end
        
        
        

        
    end % end public methods
    
    % ----------------------------------------------------
    %  PRIVATE methods
    % ----------------------------------------------------
    methods(Access=protected)
        
        function []=sendByte(me,b)
            fwrite(me.m_serial, uint8(b),'uint8');
            if (me.verbosity_level>=2)
                fprintf('%02X ',b);
            end
        end
        function []=sendByteWithStuffing(me,b)
            fwrite(me.m_serial, uint8(b),'uint8');
            if (me.usb_protocol && b==me.DLE)
                fwrite(me.m_serial, uint8(b),'uint8');
            end
            if (me.verbosity_level>=2)
                fprintf('%02X ',b);
            end
        end
        
        
        function []=sendWord(me,w16)
            lb = uint8(bitand(w16,h('0xff')));
            hb = uint8( bitsrl(w16,8));
            
            fwrite(me.m_serial, lb,'uint8'); % low byte
            if (me.usb_protocol && lb==me.DLE)
                fwrite(me.m_serial, lb,'uint8');
            end
                
            fwrite(me.m_serial, hb,'uint8'); % high byte       
            if (me.usb_protocol && hb==me.DLE)
                fwrite(me.m_serial, hb,'uint8');
            end
            if (me.verbosity_level>=2)
                fprintf('%04X ',w16);
            end
        end

    end % end methods
    
    % ----------------------------------------------------
    %  Private properties
    % ----------------------------------------------------
    properties(Access=protected)
        m_serial = []; % Serial port object
        
        % Frame protocol bytes:
        DLE = 144; % 0x90
        STX = 2;   % 0x02
        
    end % end protected props    
end

