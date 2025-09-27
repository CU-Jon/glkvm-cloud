/*
 * @Author: CU-Jon
 * @Date: 2025-09-26 13:28:12 EDT
 * @LastEditors: CU-Jon
 * @LastEditTime: 2025-09-26 14:02:57 EDT
 * @FilePath: \glkvm-cloud\ldap.go
 * @Description: LDAP认证模块 (LDAP authentication module)
 */

package main

import (
	"crypto/tls"
	"fmt"
	"strings"
	"time"

	"github.com/go-ldap/ldap/v3"
	"github.com/rs/zerolog/log"
)

// LDAP认证器结构体 (LDAP authenticator struct)
type LDAPAuthenticator struct {
	config *Config
}

// 创建新的LDAP认证器 (Create new LDAP authenticator)
func NewLDAPAuthenticator(config *Config) *LDAPAuthenticator {
	return &LDAPAuthenticator{config: config}
}

// 执行用户LDAP认证 (Perform LDAP authentication for a user)
func (l *LDAPAuthenticator) Authenticate(username, password string) (bool, error) {
	if !l.config.LdapEnabled {
		return false, fmt.Errorf("LDAP authentication is disabled")
	}

	if username == "" || password == "" {
		return false, fmt.Errorf("username and password are required")
	}

	// 连接到LDAP服务器 (Connect to LDAP server)
	conn, err := l.connect()
	if err != nil {
		return false, fmt.Errorf("failed to connect to LDAP server: %v", err)
	}
	defer conn.Close()

	// 使用服务账户进行绑定和搜索 (Use service account for binding and searching)
	if l.config.LdapBindDN == "" || l.config.LdapBindPassword == "" {
		return false, fmt.Errorf("service account credentials are required for LDAP authentication - BindDN empty: %v, BindPassword empty: %v", l.config.LdapBindDN == "", l.config.LdapBindPassword == "")
	}

	err = conn.Bind(l.config.LdapBindDN, l.config.LdapBindPassword)
	if err != nil {
		return false, fmt.Errorf("service account bind failed: %v", err)
	}	// 使用服务账户搜索用户 (Use service account to search for user)
	userDN, err := l.findUserDN(conn, username)
	if err != nil {
		return false, fmt.Errorf("user search failed: %v", err)
	}
	
	// 找到用户，现在用用户凭证验证密码 (Found user, now validate password with user credentials)
	err = conn.Bind(userDN, password)
	if err != nil {
		return false, fmt.Errorf("password validation failed: %v", err)
	}
	
	// 重新绑定为服务账户以进行授权检查 (Rebind as service account for authorization check)
	err = conn.Bind(l.config.LdapBindDN, l.config.LdapBindPassword)
	if err != nil {
		return false, fmt.Errorf("failed to rebind as service account for authorization: %v", err)
	}
	
	// 检查用户授权 (Check user authorization)
	authorized, err := l.checkAuthorization(conn, userDN, username)
	if err != nil {
		return false, fmt.Errorf("authorization check failed: %v", err)
	}

	if !authorized {
		return false, fmt.Errorf("user not authorized")
	}

	return true, nil
}

// 建立到LDAP服务器的连接 (Establish connection to LDAP server)
func (l *LDAPAuthenticator) connect() (*ldap.Conn, error) {
	address := fmt.Sprintf("%s:%d", l.config.LdapServer, l.config.LdapPort)
	
	var conn *ldap.Conn
	var err error

	if l.config.LdapUseTLS {
		// TLS配置 (TLS configuration)
		tlsConfig := &tls.Config{
			ServerName: l.config.LdapServer,
			InsecureSkipVerify: true, // 跳过证书验证以避免自签名证书问题 (Skip certificate verification to avoid self-signed certificate issues)
		}
		
		if l.config.LdapPort == 636 {
			// 使用LDAPS (直接TLS连接) (Use LDAPS - direct TLS connection)
			conn, err = ldap.DialTLS("tcp", address, tlsConfig)
		} else {
			// 使用StartTLS (先连接再升级到TLS) (Use StartTLS - connect first then upgrade to TLS)
			conn, err = ldap.Dial("tcp", address)
			if err == nil {
				err = conn.StartTLS(tlsConfig)
			}
		}
	} else {
		// 使用普通连接 (Use plain connection)
		conn, err = ldap.Dial("tcp", address)
	}

	if err != nil {
		return nil, err
	}

	// 设置超时时间 (Set timeout)
	conn.SetTimeout(10 * time.Second)

	return conn, nil
}

// 基于用户名搜索用户DN (Search for user DN based on username)
func (l *LDAPAuthenticator) findUserDN(conn *ldap.Conn, username string) (string, error) {
	// 准备搜索过滤器 (Prepare search filter)
	filter := fmt.Sprintf(l.config.LdapUserFilter, username)
	if l.config.LdapUserFilter == "" {
		filter = fmt.Sprintf("(uid=%s)", username)
	}

	// 执行搜索 (Perform search)
	searchRequest := ldap.NewSearchRequest(
		l.config.LdapBaseDN,
		ldap.ScopeWholeSubtree,
		ldap.NeverDerefAliases,
		0, // 无大小限制 (No size limit)
		0, // 无时间限制 (No time limit)
		false,
		filter,
		[]string{"dn"},
		nil,
	)

	sr, err := conn.Search(searchRequest)
	if err != nil {
		return "", err
	}

	if len(sr.Entries) == 0 {
		return "", fmt.Errorf("user not found")
	}

	if len(sr.Entries) > 1 {
		return "", fmt.Errorf("multiple users found")
	}

	return sr.Entries[0].DN, nil
}

// 基于组或用户列表检查用户是否授权 (Check if user is authorized based on groups or users list)
func (l *LDAPAuthenticator) checkAuthorization(conn *ldap.Conn, userDN, username string) (bool, error) {
	// 如果没有配置限制，则允许所有已认证用户 (If no restrictions are configured, allow all authenticated users)
	if l.config.LdapAllowedGroups == "" && l.config.LdapAllowedUsers == "" {
		return true, nil
	}

	// 检查允许的用户列表 (Check allowed users list)
	if l.config.LdapAllowedUsers != "" {
		allowedUsers := strings.Split(strings.TrimSpace(l.config.LdapAllowedUsers), ",")
		for _, allowedUser := range allowedUsers {
			if strings.TrimSpace(allowedUser) == username {
				return true, nil
			}
		}
	}

	// 检查允许的组 (Check allowed groups)
	if l.config.LdapAllowedGroups != "" {
		return l.checkGroupMembership(conn, userDN, username)
	}

	return false, nil
}

// 检查用户是否属于任何允许的组 (Check if user belongs to any of the allowed groups)
func (l *LDAPAuthenticator) checkGroupMembership(conn *ldap.Conn, userDN, username string) (bool, error) {
	allowedGroups := strings.Split(strings.TrimSpace(l.config.LdapAllowedGroups), ",")
	
	for _, group := range allowedGroups {
		group = strings.TrimSpace(group)
		if group == "" {
			continue
		}

		// 搜索组成员关系 - 尝试不同的常见LDAP组结构 (Search for group membership - try different common LDAP group structures)
		isMember, err := l.isGroupMember(conn, userDN, username, group)
		if err != nil {
			log.Warn().Msgf("Error checking group membership for %s in %s: %v", username, group, err)
			continue
		}

		if isMember {
			return true, nil
		}
	}

	return false, nil
}

// 检查用户是否是指定组的成员 (Check if user is a member of the specified group)
func (l *LDAPAuthenticator) isGroupMember(conn *ldap.Conn, userDN, username, groupName string) (bool, error) {
	// 首先查找用户的实际DN，因为我们可能使用了UPN格式进行认证 (First find the user's actual DN, as we may have used UPN format for authentication)
	actualUserDN, err := l.findActualUserDN(conn, username)
	if err != nil {
		actualUserDN = userDN // 回退到原始DN (Fallback to original DN)
	}
	
	// 尝试不同的常见组搜索模式 (Try different common group search patterns)
	
	// 模式1：通过CN搜索组并检查成员属性 (Pattern 1: Search for group by CN and check member attribute)
	groupFilter := fmt.Sprintf("(cn=%s)", groupName)
	
	groupSearchRequest := ldap.NewSearchRequest(
		l.config.LdapBaseDN,
		ldap.ScopeWholeSubtree,
		ldap.NeverDerefAliases,
		0, 0, false,
		groupFilter,
		[]string{"member", "memberUid", "uniqueMember"},
		nil,
	)

	sr, err := conn.Search(groupSearchRequest)
	if err != nil {
		log.Warn().Msgf("Group search failed: %v", err)
		return false, err
	}
	
	for _, entry := range sr.Entries {
		members := entry.GetAttributeValues("member")
		memberUids := entry.GetAttributeValues("memberUid")
		uniqueMembers := entry.GetAttributeValues("uniqueMember")
		
		// 检查member属性（完整DN） (Check member attribute - full DN)
		for _, member := range members {
			if member == userDN || member == actualUserDN {
				return true, nil
			}
			// 也检查是否member DN包含用户名 (Also check if member DN contains the username)
			if strings.Contains(strings.ToLower(member), strings.ToLower("cn="+username)) {
				return true, nil
			}
		}
		
		// 检查memberUid属性（仅用户名） (Check memberUid attribute - username only)
		for _, memberUid := range memberUids {
			if memberUid == username {
				return true, nil
			}
		}
		
		// 检查uniqueMember属性（完整DN） (Check uniqueMember attribute - full DN)
		for _, uniqueMember := range uniqueMembers {
			if uniqueMember == userDN {
				return true, nil
			}
		}
	}

	// 模式2：通过用户名搜索用户并检查memberOf属性 (Pattern 2: Search for user by username and check memberOf attribute)
	
	// 使用配置的用户过滤器或默认的uid过滤器 (Use configured user filter or default uid filter)
	userFilter := fmt.Sprintf(l.config.LdapUserFilter, username)
	if l.config.LdapUserFilter == "" {
		userFilter = fmt.Sprintf("(uid=%s)", username)
	}
	
	userSearchRequest := ldap.NewSearchRequest(
		l.config.LdapBaseDN,
		ldap.ScopeWholeSubtree,
		ldap.NeverDerefAliases,
		0, 0, false,
		userFilter,
		[]string{"memberOf", "distinguishedName"},
		nil,
	)

	sr, err = conn.Search(userSearchRequest)
	if err != nil {
		log.Warn().Msgf("User search for memberOf failed: %v", err)
	} else {
		for _, entry := range sr.Entries {
			memberOfValues := entry.GetAttributeValues("memberOf")
			
			for _, memberOf := range memberOfValues {
				if strings.Contains(strings.ToLower(memberOf), strings.ToLower("cn="+groupName)) {
					return true, nil
				}
			}
		}
	}

	return false, nil
}

// 查找用户的实际DN (Find the user's actual DN)
func (l *LDAPAuthenticator) findActualUserDN(conn *ldap.Conn, username string) (string, error) {
	// 使用配置的用户过滤器搜索用户 (Search for user using configured user filter)
	userFilter := fmt.Sprintf(l.config.LdapUserFilter, username)
	if l.config.LdapUserFilter == "" {
		userFilter = fmt.Sprintf("(uid=%s)", username)
	}
	
	userSearchRequest := ldap.NewSearchRequest(
		l.config.LdapBaseDN,
		ldap.ScopeWholeSubtree,
		ldap.NeverDerefAliases,
		0, 0, false,
		userFilter,
		[]string{"distinguishedName"},
		nil,
	)

	sr, err := conn.Search(userSearchRequest)
	if err != nil {
		return "", err
	}

	if len(sr.Entries) == 0 {
		return "", fmt.Errorf("user not found")
	}

	if len(sr.Entries) > 1 {
		return "", fmt.Errorf("multiple users found")
	}

	return sr.Entries[0].DN, nil
}

// 执行用户认证，支持LDAP和传统密码认证 (Perform user authentication with LDAP and legacy password support)
func AuthenticateUser(cfg *Config, username, password, authMethod string) bool {
	success, _ := AuthenticateUserWithError(cfg, username, password, authMethod)
	return success
}

// 执行用户认证并返回错误类型，支持LDAP和传统密码认证 (Perform user authentication with error type, supporting LDAP and legacy password authentication)
func AuthenticateUserWithError(cfg *Config, username, password, authMethod string) (bool, string) {
	// 处理LDAP认证 (Handle LDAP authentication)
	if cfg.LdapEnabled && authMethod == "ldap" && username != "" {
		ldapAuth := NewLDAPAuthenticator(cfg)
		success, err := ldapAuth.Authenticate(username, password)
		if err != nil {
			log.Error().Msgf("LDAP authentication error: %v", err)
			// 检查错误类型以区分认证和授权错误 (Check error type to distinguish between authentication and authorization errors)
			if strings.Contains(err.Error(), "user not authorized") {
				return false, "authorization"
			}
			return false, "authentication"
		}
		return success, ""
	}

	// 回退到原始密码认证以保持向后兼容 (Fallback to original password authentication for backward compatibility)
	if authMethod == "legacy" || authMethod == "" {
		if cfg.Password == password {
			return true, ""
		}
		return false, "authentication"
	}

	return false, "authentication"
}