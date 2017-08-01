--[[
模块名称：虚拟串口AT命令交互管理
模块功能：AT交互
模块最后修改时间：2017.02.13
]]

-- 定义模块,导入依赖库
local base = _G
local table = require"table"
local string = require"string"
local uart = require"uart"
local rtos = require"rtos"
local sys = require"sys"
module("ril")

--加载常用的全局函数至本地
local setmetatable = base.setmetatable
local print = base.print
local type = base.type
local smatch = string.match
local sfind = string.find
local vwrite = uart.write
local vread = uart.read

--是否为透传模式，true为透传模式，false或者nil为非透传模式
--默认非透传模式
local transparentmode
--透传模式下，虚拟串口数据接收的处理函数
local rcvfunc

--执行AT命令后1分钟无反馈，判定at命令执行失败，则重启软件
local TIMEOUT,RETRYTIMEOUT,RETRY_MAX = 60000,1000,5 --1分钟无反馈 判定at命令执行失败

--[[
AT命令的应答类型:
  NORESULT: 收到的应答数据当做urc通知处理，如果发送的AT命令不处理应答或者没有设置类型，默认为此类型
  NUMBERIC: 纯数字类型；例如发送AT+CGSN命令，应答的内容为：862991527986589\r\nOK，此类型指的是862991527986589这一部分为纯数字类型
  SLINE: 有前缀的单行字符串类型；例如发送AT+CSQ命令，应答的内容为：+CSQ: 23,99\r\nOK，此类型指的是+CSQ: 23,99这一部分为单行字符串类型
  MLINE: 有前缀的多行字符串类型；例如发送AT+CMGR=5命令，应答的内容为：+CMGR: 0,,84\r\n0891683108200105F76409A001560889F800087120315123842342050003590404590D003A59\r\nOK，此类型指的是OK之前为多行字符串类型
  STRING: 无前缀的字符串类型，例如发送AT+ATWMFT=99命令，应答的内容为：SUCC\r\nOK，此类型指的是SUCC
]]
local NORESULT,NUMBERIC,SLINE,MLINE,STRING = 0,1,2,3,4

--AT命令的应答类型表，预置了如下几项
local RILCMD = {
	["+CSQ"] = 2,
	["+CGSN"] = 1,
	["+WISN"] = 2,
	["+AUD"] = 2,
	["+VER"] = 2,
	["+BLVER"] = 2,
	["+CIMI"] = 1,
	["+ICCID"] = 2,
	["+CGATT"] = 2,
	["+CCLK"] = 2,
	["+CPIN"] = 2,
	["+ATWMFT"] = 4,
	["+CMGR"] = 3,
	["+CMGS"] = 2,
	["+CPBF"] = 3,
	["+CPBR"] = 3, 	
}

--radioready：AT命令通道是否准备就绪
--delaying：执行完某些AT命令前，需要延时一段时间，才允许执行这些AT命令；此标志表示是否在延时状态
local radioready,delaying = false

--AT命令队列
local cmdqueue = {
	{cmd = "ATE0",retry = {max=25,timeout=2000}},
	"AT+CMEE=0",
	"AT+VER",
	"AT+BLVER"
}
-- 当前正在执行的AT命令,参数,反馈回调,延迟执行时间,重试,命令头,类型,反馈格式
local currcmd,currarg,currsp,curdelay,curetry,cmdhead,cmdtype,rspformt
-- 反馈结果,中间信息,结果信息
local result,interdata,respdata

--ril会出现三种情况: 
--发送AT命令，收到应答
--发送AT命令，命令超时没有应答
--底层软件主动上报的通知，下文我们简称为urc

--[[
函数名：atimeout
功能  ：发送AT命令，命令超时没有应答的处理
参数  ：无
返回值：无
]]
local function atimeout()
	--命令响应超时自动重启系统
	sys.restart("ril.atimeout_"..(currcmd or ""))
end

local function retrytimeout()
	print("retrytimeout",currcmd,curetry)
	if curetry and currcmd then
		if not curetry.cnt then curetry.cnt=0 end
		if curetry.cnt<=(curetry.max or RETRY_MAX) then
			sys.timer_start(retrytimeout,curetry.timeout or RETRYTIMEOUT)
			print("sendat retry:",currcmd)
			vwrite(uart.ATC,currcmd .. "\r")
			curetry.cnt = curetry.cnt+1
		else
			if curetry.skip then rsp() end
		end
	end
end

--[[
函数名：defrsp
功能  ：AT命令的默认应答处理。如果没有定义某个AT的应答处理函数，则会走到本函数
参数  ：
		cmd：此应答对应的AT命令
		success：AT命令执行结果，true或者false
		response：AT命令的应答中的执行结果字符串
		intermediate：AT命令的应答中的中间信息
返回值：无
]]
local function defrsp(cmd,success,response,intermediate)
	print("default response:",cmd,success,response,intermediate)
end

--AT命令的应答处理表
local rsptable = {}
setmetatable(rsptable,{__index = function() return defrsp end})

--自定义的AT命令应答格式表，当AT命令应答为STRING格式时，用户可以进一步定义这里面的格式
local formtab = {}

--[[
函数名：regrsp
功能  ：注册某个AT命令应答的处理函数
参数  ：
		head：此应答对应的AT命令头，去掉了最前面的AT两个字符
		fnc：AT命令应答的处理函数
		typ：AT命令的应答类型，取值范围NORESULT,NUMBERIC,SLINE,MLINE,STRING,SPECIAL
		formt：typ为STRING时，进一步定义STRING中的详细格式
返回值：成功返回true，失败false
]]
function regrsp(head,fnc,typ,formt)
	--没有定义应答类型
	if typ == nil then
		rsptable[head] = fnc
		return true
	end
	--定义了合法应答类型
	if typ == 0 or typ == 1 or typ == 2 or typ == 3 or typ == 4 then
		--如果AT命令的应答类型已存在，并且与新设置的不一致
		if RILCMD[head] and RILCMD[head] ~= typ then
			return false
		end
		--保存
		RILCMD[head] = typ
		rsptable[head] = fnc
		formtab[head] = formt
		return true
	else
		return false
	end
end

--[[
函数名：rsp
功能  ：AT命令的应答处理
参数  ：无
返回值：无
]]
function rsp()
	--停止应答超时定时器
	sys.timer_stop(atimeout)
	sys.timer_stop(retrytimeout)

	--如果发送AT命令时已经同步指定了应答处理函数
	if currsp then
		currsp(currcmd,result,respdata,interdata)
	--用户注册的应答处理函数表中找到处理函数
	else
		rsptable[cmdhead](currcmd,result,respdata,interdata)
	end
	--重置全局变量
	currcmd,currarg,currsp,curdelay,curetry,cmdhead,cmdtype,rspformt = nil
	result,interdata,respdata = nil
end

--[[
函数名：defurc
功能  ：urc的默认处理。如果没有定义某个urc的应答处理函数，则会走到本函数
参数  ：
		data：urc内容
返回值：无
]]
local function defurc(data)
	print("defurc:",data)
end

--urc的处理表
local urctable = {}
setmetatable(urctable,{__index = function() return defurc end})

--[[
函数名：regurc
功能  ：注册某个urc的处理函数
参数  ：
		prefix：urc前缀，最前面的连续字符串，包含+、大写字符、数字的组合
		handler：urc的处理函数
返回值：无
]]
function regurc(prefix,handler)
	urctable[prefix] = handler
end

--[[
函数名：deregurc
功能  ：解注册某个urc的处理函数
参数  ：
		prefix：urc前缀，最前面的连续字符串，包含+、大写字符、数字的组合
返回值：无
]]
function deregurc(prefix)
	urctable[prefix] = nil
end

--“数据过滤器”，虚拟串口收到的数据时，首先需要调用此函数过滤处理一下
local urcfilter

local function kickoff()
	radioready = true
	sendat()
end

--[[
函数名：urc
功能  ：urc处理
参数  ：
		data：urc数据
返回值：无
]]
local function urc(data)
	--AT通道准备就绪
	if data == "RDY" then
		radioready = true
	else
		local prefix = smatch(data,"(%+*[%u%d& ]+)")
		--执行prefix的urc处理函数，返回数据过滤器
		urcfilter = urctable[prefix](data,prefix)
	end
end

local function printrcv(data)
	if data=="\r\n" then return end
	if smatch(data,"^%+CENG:.+\r\n$") then return end
	if sys.getworkmode()==sys.SIMPLE_MODE then
		if --[[smatch(data,"^%+CENG:.+\r\n$") or ]]smatch(data,"^%+CPIN:.+\r\n$") then return end
		if data=="OK\r\n" and currcmd=="AT+CPIN?" then return end
	end
	
	return true
end

--[[
函数名：procatc
功能  ：处理虚拟串口收到的数据
参数  ：
		data：收到的数据
返回值：无
]]
local function procatc(data)
	if printrcv(data) then print("atc:",data) end
	
  -- 继续接收多行反馈直至出现OK为止
	if interdata and cmdtype == MLINE then
		-- 多行反馈的命令如果接收到中间数据说明执行成功了,判定之后的数据结束就是OK
		if data ~= "OK\r\n" then
    -- 去掉最后的换行符
			if sfind(data,"\r\n",-2) then
				data = string.sub(data,1,-3)
			end
			--拼接到中间数据
			interdata = interdata .. "\r\n" .. data
			return
		end
	end
	--如果存在“数据过滤器”
	if urcfilter then
		data,urcfilter = urcfilter(data)
	end
  -- 若最后两个字节是\r\n则删掉
	if sfind(data,"\r\n",-2) then
		data = string.sub(data,1,-3)
	end
	--数据为空
	if data == "" then
		return
	end

  -- 当前无命令在执行则判定为urc
	if currcmd == nil then
		urc(data)
		return
	end

	local isurc = false

	--一些特殊的错误信息，转化为ERROR统一处理
	if sfind(data,"^%+CMS ERROR:") or sfind(data,"^%+CME ERROR:") then
		data = "ERROR"
	end
	--执行成功的应答
	if data == "OK" then
		result = true
		respdata = data
	--执行失败的应答
	elseif data == "ERROR" or data == "NO ANSWER" or data == "NO DIALTONE" then
		result = false
		respdata = data
	elseif data == "NO CARRIER" and currcmd=="ATA" then
    result = false
    respdata = data
  --需要继续输入参数的AT命令应答
	elseif data == "> " then
		if cmdhead == "+CMGS" then -- 根据提示符发送短信或者数据
			print("send:",currarg)
			vwrite(uart.ATC,currarg,"\026")		
		else
			print("error promot cmd:",currcmd)
		end
	else
		--根据命令类型来判断收到的数据是urc或者反馈数据
		if cmdtype == NORESULT then -- 无结果命令 此时收到的数据只有URC
			isurc = true
		elseif cmdtype == NUMBERIC then -- 全数字
			local numstr = smatch(data,"(%x+)")
			if numstr == data then
				interdata = data
			else
				isurc = true
			end
		elseif cmdtype == STRING then -- 字符串
			if smatch(data,rspformt or "^%w+$") then
				interdata = data
			else
				isurc = true
			end
		elseif cmdtype == SLINE or cmdtype == MLINE then
			if interdata == nil and sfind(data, cmdhead) == 1 then
				interdata = data
			else
				isurc = true
			end		
		else
			isurc = true
		end
	end

	if isurc then
		urc(data)
	elseif result ~= nil then
		rsp()
	end
end

--是否在读取虚拟串口数据
local readat = false

--[[
函数名：getcmd
功能  ：解析一条AT命令
参数  ：
		item：AT命令
返回值：当前AT命令的内容
]]
local function getcmd(item)
	local cmd,arg,rsp,delay,retry
	--命令是string类型
	if type(item) == "string" then
		--命令内容
		cmd = item
	--命令是table类型
	elseif type(item) == "table" then
		--命令内容
		cmd = item.cmd
		--命令参数
		arg = item.arg
		--命令应答处理函数
		rsp = item.rsp
		--命令延时执行时间
		delay = item.delay
		retry = item.retry
	else
		print("getpack unknown item")
		return
	end
	--命令前缀
	head = smatch(cmd,"AT([%+%*]*%u+)")

	if head == nil then
		print("request error cmd:",cmd)
		return
	end

	if head == "+CMGS" then -- 必须有参数
		if arg == nil or arg == "" then
			print("request error no arg",head)
			return
		end
	end

	--赋值全局变量
	currcmd = cmd
	currarg = arg
	currsp = rsp
	curdelay = delay
	curetry = retry
	cmdhead = head
	cmdtype = RILCMD[head] or NORESULT
	rspformt = formtab[head]

	return currcmd
end

--[[
函数名：sendat
功能  ：发送AT命令
参数  ：无
返回值：无
]]
function sendat()
	--print("sendat",radioready,readat,currcmd,delaying)
	if not radioready or readat or currcmd ~= nil or delaying then
		-- 未初始化/正在读取atc数据、有命令在执行、队列无命令 直接退出
		return
	end

	local item

	while true do
		--队列无AT命令
		if #cmdqueue == 0 then
			return
		end
		--读取第一条命令
		item = table.remove(cmdqueue,1)
		--解析命令
		getcmd(item)
		--需要延迟发送
		if curdelay then
			--启动延迟发送定时器
			sys.timer_start(delayfunc,curdelay)
			--清除全局变量
			currcmd,currarg,currsp,curdelay,cmdhead,cmdtype,rspformt = nil
			item.delay = nil
			--设置延迟发送标志
			delaying = true
			--把命令重新插入命令队列的队首
			table.insert(cmdqueue,1,item)
			return
		end

		if currcmd ~= nil then
			break
		end
	end
	--启动AT命令应答超时定时器
	sys.timer_start(atimeout,TIMEOUT)
	if curetry then sys.timer_start(retrytimeout,curetry.timeout or RETRYTIMEOUT) end

	if not (sys.getworkmode()==sys.SIMPLE_MODE and currcmd=="AT+CPIN?") then
		print("sendat:",currcmd)
	end
	--向虚拟串口中发送AT命令
	vwrite(uart.ATC,currcmd .. "\r")
end

--[[
函数名：delayfunc
功能  ：延时执行某条AT命令的定时器回调
参数  ：无
返回值：无
]]
function delayfunc()
	--清除延时标志
	delaying = nil
	--执行AT命令发送
	sendat()
end

--[[
函数名：atcreader
功能  ：“AT命令的虚拟串口数据接收消息”的处理函数，当虚拟串口收到数据时，会走到此函数中
参数  ：无
返回值：无
]]
local function atcreader()
	local s

	if not transparentmode then readat = true end
	--循环读取虚拟串口收到的数据
	while true do
		--每次读取一行
		s = vread(uart.ATC,"*l",0)

		if string.len(s) ~= 0 then
			if transparentmode then
				--透传模式下直接转发数据
				rcvfunc(s)
			else
                        --非透传模式下处理收到的数据
			procatc(s)
			end
		else
			break
		end
	end
  if not transparentmode then
    readat = false
    --atc上报数据处理完以后才执行发送AT命令
    sendat()
  end
end

--注册“AT命令的虚拟串口数据接收消息”的处理函数
sys.regmsg("atc",atcreader)

--[[
函数名：request
功能  ：发送AT命令到底层软件
参数  ：
		cmd：AT命令内容
		arg：AT命令参数，例如AT+CMGS=12命令执行后，接下来会发送此参数；AT+CIPSEND=14命令执行后，接下来会发送此参数
		onrsp：AT命令应答的处理函数，只是当前发送的AT命令应答有效，处理之后就失效了
		delay：延时delay毫秒后，才发送此AT命令
		retry: 重试
返回值：无
]]
function request(cmd,arg,onrsp,delay,retry)
	if transparentmode then return end
	--插入缓冲队列
	if arg or onrsp or delay or retry then
		table.insert(cmdqueue,{cmd = cmd,arg = arg,rsp = onrsp,delay = delay,retry = retry})
	else
		table.insert(cmdqueue,cmd)
	end
	--执行AT命令发送
	sendat()
end

sys.timer_start(kickoff,3000)

--[[
函数名：setransparentmode
功能  ：AT命令通道设置为透传模式
参数  ：
		fnc：透传模式下，虚拟串口数据接收的处理函数
返回值：无
注意：透传模式和非透传模式，只支持开机的第一次设置，不支持中途切换
]]
function setransparentmode(fnc)
	transparentmode,rcvfunc = true,fnc
end

--[[
函数名：sendtransparentdata
功能  ：透传模式下发送数据
参数  ：
		data：数据
返回值：成功返回true，失败返回nil
]]
function sendtransparentdata(data)
	if not transparentmode then return end
	vwrite(uart.ATC,data)
	return true
end

