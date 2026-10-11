package cmd

import (
	"github.com/spf13/cobra"

	"github.com/filebrowser/filebrowser/v2/settings"
	"github.com/filebrowser/filebrowser/v2/users"
)

func init() {
	usersCmd.AddCommand(usersAddCmd)
	addUserFlags(usersAddCmd.Flags())
}

var usersAddCmd = &cobra.Command{
	Use:   "add <username> <password>",
	Short: "Create a new user",
	Long:  `Create a new user and add it to the database.`,
	Args:  cobra.ExactArgs(2),
	RunE:  withStore(addUser, storeOptions{}),
}

func addUser(cmd *cobra.Command, args []string, st *store) error {
	flags := cmd.Flags()
	s, err := st.Settings.Get()
	if err != nil {
		return err
	}
	err = getUserDefaults(flags, &s.Defaults, false)
	if err != nil {
		return err
	}

	user, err := s.NewUser(args[0], args[1], settings.ProvisionCLI)
	if err != nil {
		return err
	}

	user.LockPassword, err = flags.GetBool("lockPassword")
	if err != nil {
		return err
	}

	servSettings, err := st.Settings.GetServer()
	if err != nil {
		return err
	}
	err = s.ProvisionUser(st.Users, user, servSettings.Root, settings.ProvisionCLI, false)
	if err != nil {
		return err
	}

	return printUsers([]*users.User{user})
}
